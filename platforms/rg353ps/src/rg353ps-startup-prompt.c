/*
 * RG353PS first-boot storage gate.
 * Runs on tty1 before the frontend selector. Uses the handheld's A button
 * (BTN_EAST in Nintendo layout) or Enter to acknowledge/retry.
 */
#define _DEFAULT_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

#define MAX_INPUTS 64
#define PATH_LEN 256
#define NAME_LEN 128

struct input_device {
    int fd;
    char path[PATH_LEN];
};

static struct input_device inputs[MAX_INPUTS];
static int input_count;
static struct termios saved_termios;
static int termios_saved;

static void restore_terminal(void)
{
    if (termios_saved)
        (void)tcsetattr(STDIN_FILENO, TCSANOW, &saved_termios);
    (void)printf("\033[0m\033[?25h");
    fflush(stdout);
}

static int attach_tty1(void)
{
    int fd = open("/dev/tty1", O_RDWR | O_CLOEXEC);
    if (fd < 0)
        return -1;
    for (int target = STDIN_FILENO; target <= STDERR_FILENO; ++target) {
        if (dup2(fd, target) < 0) {
            (void)close(fd);
            return -1;
        }
    }
    if (fd > STDERR_FILENO)
        (void)close(fd);
    return 0;
}

static void draw_screen(const char *mode)
{
    (void)printf("\033[0m\033[2J\033[H\033[?25l");
    (void)printf("\033[2;8H+----------------------------------------------------------------+");
    (void)printf("\033[3;8H|                         BASEOS RG353PS                        |");
    (void)printf("\033[4;8H+----------------------------------------------------------------+");

    if (strcmp(mode, "initializing") == 0) {
        (void)printf("\033[8;1H");
        (void)printf("                         PREPARING USER STORAGE\n\n");
        (void)printf("        BaseOS is preparing the TF card user-data partition.\n");
        (void)printf("        It may expand the partition and create an exFAT filesystem.\n\n");
        (void)printf("        Please keep the device powered on. Do not remove the card.\n");
        (void)printf("        The frontend and diagnostic UI will not start yet.\n");
    } else if (strcmp(mode, "ready") == 0) {
        (void)printf("\033[8;1H");
        (void)printf("                         USER STORAGE IS READY\n\n");
        (void)printf("        The TF1 user-data partition is mounted and ready.\n");
        (void)printf("        BaseOS will now search for a frontend automatically.\n");
        (void)printf("        TF2 has priority; TF1 is used if TF2 has no usable frontend.\n\n");
        (void)printf("        Press A (the right face button) or Enter to continue.\n");
    } else if (strcmp(mode, "usb-storage") == 0) {
        (void)printf("\033[8;1H");
        (void)printf("                         USB STORAGE MODE ACTIVE\n\n");
        (void)printf("        Connect the RG353PS USB data cable to your computer.\n\n");
        (void)printf("        The selected TF card is being exposed as USB Mass Storage.\n");
        (void)printf("        Do not remove the card or power off while the computer\n");
        (void)printf("        is reading or writing files.\n\n");
        (void)printf("        When finished, safely eject the disk and unplug the cable.\n");
        (void)printf("        The device will return to BaseOS automatically.\n");
    } else {
        (void)printf("\033[8;1H");
        (void)printf("                         USER STORAGE NOT READY\n\n");
        (void)printf("        BaseOS could not finish mounting the TF1 user-data area.\n");
        (void)printf("        It will not start the diagnostic UI while storage is unavailable.\n\n");
        (void)printf("        Check that the BASEOS_DATA partition exists and is exFAT.\n");
        (void)printf("        Press A (the right face button) or Enter to retry.\n");
        (void)printf("        The detailed reason is recorded in the kernel log.\n");
    }
    fflush(stdout);
}

static void discover_inputs(void)
{
    DIR *dir = opendir("/dev/input");
    struct dirent *entry;

    input_count = 0;
    if (dir == NULL)
        return;

    while ((entry = readdir(dir)) != NULL && input_count < MAX_INPUTS) {
        char path[PATH_LEN];
        char name[NAME_LEN] = "unknown";
        int fd;

        if (strncmp(entry->d_name, "event", 5) != 0)
            continue;
        if (snprintf(path, sizeof(path), "/dev/input/%s", entry->d_name) >= (int)sizeof(path))
            continue;
        fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
        if (fd < 0)
            continue;
        if (ioctl(fd, EVIOCGNAME(sizeof(name)), name) < 0 ||
            strstr(name, "gpio-keys-control") == NULL) {
            (void)close(fd);
            continue;
        }
        inputs[input_count].fd = fd;
        (void)snprintf(inputs[input_count].path, sizeof(inputs[input_count].path), "%s", path);
        ++input_count;
    }
    (void)closedir(dir);
}

static int wait_for_confirmation(void)
{
    struct pollfd pollfds[MAX_INPUTS + 1];
    int stdin_active = isatty(STDIN_FILENO);

    if (stdin_active && tcgetattr(STDIN_FILENO, &saved_termios) == 0) {
        struct termios raw = saved_termios;
        raw.c_lflag &= (tcflag_t)~(ICANON | ECHO);
        raw.c_iflag &= (tcflag_t)~(IXON | ICRNL);
        raw.c_cc[VMIN] = 0;
        raw.c_cc[VTIME] = 0;
        if (tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0)
            termios_saved = 1;
    }

    discover_inputs();
    for (;;) {
        nfds_t count = 0;
        int stdin_index = -1;

        if (stdin_active) {
            stdin_index = (int)count;
            pollfds[count].fd = STDIN_FILENO;
            pollfds[count].events = POLLIN;
            pollfds[count].revents = 0;
            ++count;
        }
        for (int i = 0; i < input_count; ++i) {
            pollfds[count].fd = inputs[i].fd;
            pollfds[count].events = POLLIN;
            pollfds[count].revents = 0;
            ++count;
        }

        int rc = poll(pollfds, count, -1);
        if (rc < 0) {
            if (errno == EINTR)
                continue;
            break;
        }

        if (stdin_index >= 0 && (pollfds[stdin_index].revents & POLLIN) != 0) {
            unsigned char bytes[32];
            ssize_t n = read(STDIN_FILENO, bytes, sizeof(bytes));
            for (ssize_t i = 0; i < n; ++i) {
                if (bytes[i] == '\r' || bytes[i] == '\n' || bytes[i] == ' ') {
                    restore_terminal();
                    return 0;
                }
            }
        }

        for (int i = 0; i < input_count; ++i) {
            if ((pollfds[(stdin_index >= 0 ? 1 : 0) + i].revents & POLLIN) == 0)
                continue;
            struct input_event ev;
            while (read(inputs[i].fd, &ev, sizeof(ev)) == (ssize_t)sizeof(ev)) {
                if (ev.type == EV_KEY && ev.code == BTN_EAST && ev.value == 1) {
                    restore_terminal();
                    return 0;
                }
            }
        }
    }

    restore_terminal();
    return 1;
}

int main(int argc, char **argv)
{
    const char *mode;

    if (argc != 2) {
        (void)fprintf(stderr, "usage: %s --initializing|--ready|--retry|--usb-storage\n", argv[0]);
        return 2;
    }
    if (strcmp(argv[1], "--initializing") == 0)
        mode = "initializing";
    else if (strcmp(argv[1], "--ready") == 0)
        mode = "ready";
    else if (strcmp(argv[1], "--retry") == 0)
        mode = "retry";
    else if (strcmp(argv[1], "--usb-storage") == 0)
        mode = "usb-storage";
    else {
        (void)fprintf(stderr, "unknown mode: %s\n", argv[1]);
        return 2;
    }

    if (attach_tty1() != 0) {
        (void)fprintf(stderr, "could not open /dev/tty1: %s\n", strerror(errno));
        return 1;
    }
    draw_screen(mode);
    if (strcmp(mode, "initializing") == 0)
        return 0;
    if (strcmp(mode, "usb-storage") == 0) {
        for (;;) pause();
    }
    return wait_for_confirmation();
}
