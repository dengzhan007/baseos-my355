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

enum device_role { ROLE_NONE = 0, ROLE_VOLUME, ROLE_POWER, ROLE_KEYS };
struct input_device { int fd; enum device_role role; char path[PATH_LEN]; char name[NAME_LEN]; };
static struct input_device inputs[MAX_INPUTS];
static int input_count;
static volatile sig_atomic_t running = 1;
static long long power_press_start_ms = -1;
static int function_down;
static int mode_down;
static int storage_latched;
static int startup_checked;
static int sd_log_active;
#define BOOT_LOG_STAGE "/run/rg353ps-boot-key.log"
#define BOOT_LOG_FINAL "/mnt/SDCARD/rg353ps-boot-key.log"

static void stop_running(int sig) { (void)sig; running = 0; }
static int userdata_is_mounted(void) {
    FILE *fp = fopen("/proc/mounts", "r");
    char line[512];
    if (fp == NULL) return 0;
    while (fgets(line, sizeof(line), fp) != NULL) {
        char device[128], mountpoint[128], type[64];
        if (sscanf(line, "%127s %127s %63s", device, mountpoint, type) == 3 &&
            strcmp(mountpoint, "/mnt/SDCARD") == 0) {
            (void)fclose(fp);
            return 1;
        }
    }
    (void)fclose(fp);
    return 0;
}
static void flush_staged_log(void) {
    int in_fd, out_fd;
    char buf[1024];
    ssize_t n;
    if (sd_log_active || !userdata_is_mounted()) return;
    in_fd = open(BOOT_LOG_STAGE, O_RDONLY | O_CLOEXEC);
    out_fd = open(BOOT_LOG_FINAL, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (out_fd < 0) { if (in_fd >= 0) close(in_fd); return; }
    if (in_fd >= 0) {
        while ((n = read(in_fd, buf, sizeof(buf))) > 0) {
            ssize_t off = 0;
            while (off < n) {
                ssize_t w = write(out_fd, buf + off, (size_t)(n - off));
                if (w < 0) { if (errno == EINTR) continue; break; }
                off += w;
            }
        }
        (void)close(in_fd);
    }
    (void)close(out_fd);
    sd_log_active = 1;
}

static long long monotonic_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return ts.tv_sec * 1000LL + ts.tv_nsec / 1000000LL;
}
static void log_message(const char *message) {
    char line[512];
    int fd;
    int n = snprintf(line, sizeof(line), "rg353ps-hotkeyd: %s\n", message);
    fd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
    if (fd >= 0) {
        if (n > 0) (void)write(fd, line, (size_t)n < sizeof(line) ? (size_t)n : sizeof(line)-1);
        (void)close(fd);
    }
    if (n > 0) {
        const char *path = sd_log_active ? BOOT_LOG_FINAL : BOOT_LOG_STAGE;
        fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
        if (fd >= 0) {
            (void)write(fd, line, (size_t)n < sizeof(line) ? (size_t)n : sizeof(line)-1);
            (void)close(fd);
        }
    }
}
static enum device_role role_for_name(const char *name) {
    if (strstr(name, "gpio-keys-vol") != NULL) return ROLE_VOLUME;
    if (strcmp(name, "rk805 pwrkey") == 0) return ROLE_POWER;
    if (strstr(name, "gpio-keys") != NULL || strstr(name, "gpio_keys") != NULL)
        return ROLE_KEYS;
    return ROLE_NONE;
}
static int usb_cable_connected(void) {
    DIR *dir;
    struct dirent *entry;
    char path[PATH_LEN], value[64];

    /* When the OTG port is connected to a PC, the UDC state is the most
       direct signal even if usb_role/extcon is absent or reports host mode. */
    dir = opendir("/sys/class/udc");
    if (dir != NULL) {
        while ((entry = readdir(dir)) != NULL) {
            FILE *fp;
            if (entry->d_name[0] == '.') continue;
            (void)snprintf(path, sizeof(path), "/sys/class/udc/%s/state", entry->d_name);
            fp = fopen(path, "r");
            if (fp != NULL) {
                if (fgets(value, sizeof(value), fp) != NULL) {
                    value[strcspn(value, "\r\n")] = '\0';
                    if (strcmp(value, "attached") == 0 || strcmp(value, "powered") == 0 ||
                        strcmp(value, "default") == 0 || strcmp(value, "addressed") == 0 ||
                        strcmp(value, "configured") == 0 || strcmp(value, "suspended") == 0) {
                        (void)fclose(fp); (void)closedir(dir); return 1;
                    }
                }
                (void)fclose(fp);
            }
        }
        (void)closedir(dir);
    }

    dir = opendir("/sys/class/usb_role");
    if (dir != NULL) {
        while ((entry = readdir(dir)) != NULL) {
            FILE *fp;
            if (entry->d_name[0] == '.') continue;
            (void)snprintf(path, sizeof(path), "/sys/class/usb_role/%s/role", entry->d_name);
            fp = fopen(path, "r");
            if (fp != NULL) {
                if (fgets(value, sizeof(value), fp) != NULL &&
                    (strstr(value, "device") != NULL || strstr(value, "peripheral") != NULL)) {
                    (void)fclose(fp); (void)closedir(dir); return 1;
                }
                (void)fclose(fp);
            }
        }
        (void)closedir(dir);
    }
    dir = opendir("/sys/class/extcon");
    if (dir != NULL) {
        while ((entry = readdir(dir)) != NULL) {
            const char *cables[] = {"cable.USB/state", "cable.USB-DEVICE/state"};
            if (entry->d_name[0] == '.') continue;
            for (size_t i = 0; i < sizeof(cables)/sizeof(cables[0]); ++i) {
                FILE *fp;
                (void)snprintf(path, sizeof(path), "/sys/class/extcon/%s/%s", entry->d_name, cables[i]);
                fp = fopen(path, "r");
                if (fp != NULL) {
                    if (fgets(value, sizeof(value), fp) != NULL && value[0] == '1') {
                        (void)fclose(fp); (void)closedir(dir); return 1;
                    }
                    (void)fclose(fp);
                }
            }
        }
        (void)closedir(dir);
    }
    return 0;
}
static int enter_usb_storage_mode(int boot_mode) {
    pid_t child = fork();
    int status;
    if (child < 0) { log_message("cannot fork USB storage mode"); return 0; }
    if (child == 0) {
        if (boot_mode)
            execl("/usr/sbin/baseos-usb-storage", "baseos-usb-storage", "--boot", (char *)NULL);
        else
            execl("/usr/sbin/baseos-usb-storage", "baseos-usb-storage", (char *)NULL);
        _exit(127);
    }
    log_message(boot_mode ? "Function/Mode held at startup; entering USB storage mode" :
                "Function/Mode held while USB cable is connected; entering USB storage mode");
    while (waitpid(child, &status, 0) < 0) {
        if (errno == EINTR) continue;
        log_message("waitpid failed for USB storage mode");
        return 0;
    }
    log_message("USB storage mode finished");
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
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
        if (role == ROLE_KEYS) {
            unsigned long key_bits[(KEY_MAX + (sizeof(unsigned long) * 8)) /
                                   (sizeof(unsigned long) * 8)];
            memset(key_bits, 0, sizeof(key_bits));
            if (ioctl(fd, EVIOCGKEY(sizeof(key_bits)), key_bits) >= 0) {
                int fn = (key_bits[KEY_F1 / (sizeof(unsigned long) * 8)] &
                          (1UL << (KEY_F1 % (sizeof(unsigned long) * 8)))) != 0;
#ifdef KEY_FN
                fn = fn || ((key_bits[KEY_FN / (sizeof(unsigned long) * 8)] &
                             (1UL << (KEY_FN % (sizeof(unsigned long) * 8)))) != 0);
#endif
                int mode = (key_bits[KEY_MODE / (sizeof(unsigned long) * 8)] &
                            (1UL << (KEY_MODE % (sizeof(unsigned long) * 8)))) != 0;
                mode = mode || ((key_bits[KEY_MENU / (sizeof(unsigned long) * 8)] &
                                 (1UL << (KEY_MENU % (sizeof(unsigned long) * 8)))) != 0);
                function_down = function_down || fn;
                mode_down = mode_down || mode;
                if (fn || mode) log_message("Function/Mode is already held when input device opens");
            }
        }
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
        } else if (dev->role == ROLE_KEYS && ev.type == EV_KEY) {
            int down = (ev.value != 0);
            if (ev.code == KEY_F1 || ev.code == KEY_FN) function_down = down;
            if (ev.code == KEY_MODE || ev.code == KEY_MENU) mode_down = down;
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
    (void)unlink(BOOT_LOG_STAGE);
    sd_log_active = 0;
    log_message("started; boot-key diagnostic logging enabled; target=/mnt/SDCARD/rg353ps-boot-key.log");
    while(running) {
        int nfds=0, rc;
        discover_inputs();
        flush_staged_log();
        if (!startup_checked) {
            int key_device_found = 0;
            for (int i = 0; i < input_count; ++i) {
                if (inputs[i].fd >= 0 && inputs[i].role == ROLE_KEYS) {
                    key_device_found = 1;
                    break;
                }
            }
            /* Do not consume the one-shot boot-key check before gpio-keys
               exists. On this board input devices may appear after daemon
               startup; discover_inputs() will retry on subsequent loops. */
            if (key_device_found) {
            int boot_mode = function_down || mode_down;
            char boot_msg[256];
            (void)snprintf(boot_msg, sizeof(boot_msg),
                "BOOT_KEY_CHECK result=sampled key_device_found=1 function_down=%d mode_down=%d decision=%s",
                function_down, mode_down, boot_mode ? "USB_STORAGE" : "NORMAL_BOOT");
            log_message(boot_msg);
            startup_checked = 1;
            if (boot_mode) {
                int marker = open("/run/baseos-usb-storage.boot-request", O_WRONLY|O_CREAT|O_TRUNC|O_CLOEXEC, 0600);
                if (marker >= 0) close(marker);
                log_message("startup storage request latched from held Function/Mode key");
            }
            {
                int ready = open("/run/rg353ps-hotkeyd.ready", O_WRONLY|O_CREAT|O_TRUNC|O_CLOEXEC, 0600);
                if (ready >= 0) close(ready);
            }
            if (boot_mode) {
                storage_latched = 1;
                (void)enter_usb_storage_mode(1);
                unlink("/run/baseos-usb-storage.boot-request");
                function_down = mode_down = 0;
            }
            }
        }
        for(int i=0;i<input_count;++i) {
            if(inputs[i].fd<0) continue;
            pollfds[nfds].fd=inputs[i].fd; pollfds[nfds].events=POLLIN; pollfds[nfds].revents=0; ++nfds;
        }
        {
            int timeout=100;
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
        if (function_down || mode_down) {
            if (!storage_latched && usb_cable_connected()) {
                storage_latched = 1;
                (void)enter_usb_storage_mode(0);
            }
        } else {
            storage_latched = 0;
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
