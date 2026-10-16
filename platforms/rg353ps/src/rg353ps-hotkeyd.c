#define _DEFAULT_SOURCE
#define _POSIX_C_SOURCE 200809L
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define MAX_INPUTS 64
#define NAME_LEN 128
#define PATH_LEN 256
#define POWER_HOLD_MS 2000

enum device_role { ROLE_NONE = 0, ROLE_VOLUME, ROLE_POWER };
struct input_device { int fd; enum device_role role; char path[PATH_LEN]; char name[NAME_LEN]; };
static struct input_device inputs[MAX_INPUTS];
static int input_count;
static volatile sig_atomic_t running = 1;
static long long power_press_start_ms = -1;

static void stop_running(int sig) { (void)sig; running = 0; }
static long long monotonic_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return ts.tv_sec * 1000LL + ts.tv_nsec / 1000000LL;
}
static void log_message(const char *message) {
    char line[256];
    int fd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
    int n = snprintf(line, sizeof(line), "rg353ps-hotkeyd: %s\n", message);
    if (fd >= 0) {
        if (n > 0) (void)write(fd, line, (size_t)n < sizeof(line) ? (size_t)n : sizeof(line)-1);
        (void)close(fd);
    }
}
static enum device_role role_for_name(const char *name) {
    if (strstr(name, "gpio-keys-vol") != NULL) return ROLE_VOLUME;
    if (strcmp(name, "rk805 pwrkey") == 0) return ROLE_POWER;
    return ROLE_NONE;
}
static int already_open(const char *path) {
    for (int i=0; i<input_count; ++i)
        if (inputs[i].fd >= 0 && strcmp(inputs[i].path,path)==0) return 1;
    return 0;
}
static void discover_inputs(void) {
    DIR *dir = opendir("/dev/input");
    struct dirent *entry;
    if (dir == NULL) return;
    while ((entry = readdir(dir)) != NULL && input_count < MAX_INPUTS) {
        char path[PATH_LEN], name[NAME_LEN] = "unknown input";
        int fd;
        enum device_role role;
        struct input_device *dev;
        if (strncmp(entry->d_name,"event",5)!=0) continue;
        if (snprintf(path,sizeof(path),"/dev/input/%s",entry->d_name)>=(int)sizeof(path)) continue;
        if (already_open(path)) continue;
        fd=open(path,O_RDONLY|O_NONBLOCK|O_CLOEXEC);
        if(fd<0) continue;
        if(ioctl(fd,EVIOCGNAME(sizeof(name)-1),name)<0) { (void)close(fd); continue; }
        name[sizeof(name)-1]='\0';
        role=role_for_name(name);
        if(role==ROLE_NONE) { (void)close(fd); continue; }
        dev=&inputs[input_count++];
        dev->fd=fd; dev->role=role;
        (void)snprintf(dev->path,sizeof(dev->path),"%s",path);
        (void)snprintf(dev->name,sizeof(dev->name),"%s",name);
        {
            char msg[200];
            (void)snprintf(msg,sizeof(msg),"watching %s (%s)",path,name);
            log_message(msg);
        }
    }
    (void)closedir(dir);
}
static int adjust_playback_volume(int up) {
    pid_t child=fork();
    int status;
    if(child<0) { log_message("fork failed while adjusting volume"); return 0; }
    if(child==0) {
        int nullfd=open("/dev/null",O_WRONLY);
        if(nullfd>=0) {
            (void)dup2(nullfd,STDOUT_FILENO); (void)dup2(nullfd,STDERR_FILENO);
            if(nullfd>STDERR_FILENO) (void)close(nullfd);
        }
        execl("/usr/bin/amixer","amixer","-c","1","set","Master","playback",up?"5%+":"5%-",(char *)NULL);
        execl("/bin/amixer","amixer","-c","1","set","Master","playback",up?"5%+":"5%-",(char *)NULL);
        _exit(127);
    }
    while(waitpid(child,&status,0)<0) {
        if(errno==EINTR) continue;
        log_message("waitpid failed while adjusting volume"); return 0;
    }
    if(WIFEXITED(status)&&WEXITSTATUS(status)==0) {
        log_message(up?"volume up: playback changed by 5%":"volume down: playback changed by 5%");
        return 1;
    }
    log_message(up?"volume up failed: amixer returned an error":"volume down failed: amixer returned an error");
    return 0;
}
static void handle_input(struct input_device *dev) {
    struct input_event ev;
    ssize_t count;
    while((count=read(dev->fd,&ev,sizeof(ev)))==(ssize_t)sizeof(ev)) {
        if(ev.type!=EV_KEY) continue;
        if(dev->role==ROLE_VOLUME) {
            if((ev.value==1||ev.value==2)&&(ev.code==KEY_VOLUMEUP||ev.code==KEY_VOLUMEDOWN))
                (void)adjust_playback_volume(ev.code==KEY_VOLUMEUP);
        } else if(dev->role==ROLE_POWER&&ev.code==KEY_POWER) {
            if(ev.value==1) { if(power_press_start_ms<0) power_press_start_ms=monotonic_ms(); }
            else if(ev.value==0) power_press_start_ms=-1;
        }
    }
    if(count<0&&errno!=EAGAIN&&errno!=EINTR) {
        char msg[200];
        (void)snprintf(msg,sizeof(msg),"read error on %s: %s",dev->path,strerror(errno));
        log_message(msg);
    }
}
int main(void) {
    struct pollfd pollfds[MAX_INPUTS];
    (void)signal(SIGINT,stop_running); (void)signal(SIGTERM,stop_running); (void)signal(SIGHUP,stop_running);
    (void)setsid();
    log_message("started; volume adjusts playback only, power held 2 seconds shuts down");
    while(running) {
        int nfds=0, rc;
        discover_inputs();
        for(int i=0;i<input_count;++i) {
            if(inputs[i].fd<0) continue;
            pollfds[nfds].fd=inputs[i].fd; pollfds[nfds].events=POLLIN; pollfds[nfds].revents=0; ++nfds;
        }
        {
            int timeout=nfds==0?500:-1;
            if(power_press_start_ms>=0) {
                long long left=POWER_HOLD_MS-(monotonic_ms()-power_press_start_ms);
                timeout=left>0?(int)left:0;
            }
            rc=poll(pollfds,(nfds_t)nfds,timeout);
        }
        if(rc<0) {
            if(errno==EINTR) continue;
            log_message("poll failed; retrying");
            { struct timespec pause={0,100000000L}; (void)nanosleep(&pause,NULL); }
            continue;
        }
        if(power_press_start_ms>=0&&monotonic_ms()-power_press_start_ms>=POWER_HOLD_MS) {
            power_press_start_ms=-1;
            log_message("power held for 2 seconds; syncing and powering off");
            sync();
            execl("/sbin/poweroff","poweroff",(char *)NULL);
            log_message("poweroff command failed");
        }
        if(rc==0) continue;
        {
            int p=0;
            for(int i=0;i<input_count;++i) {
                if(inputs[i].fd<0) continue;
                if((pollfds[p].revents&POLLIN)!=0) handle_input(&inputs[i]);
                if((pollfds[p].revents&(POLLHUP|POLLERR|POLLNVAL))!=0) {
                    (void)close(inputs[i].fd); inputs[i].fd=-1;
                }
                ++p;
            }
        }
    }
    for(int i=0;i<input_count;++i) if(inputs[i].fd>=0) (void)close(inputs[i].fd);
    log_message("stopped");
    return 0;
}
