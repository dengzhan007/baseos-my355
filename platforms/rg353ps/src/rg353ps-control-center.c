/*
 * RG353PS interactive bring-up console.
 * Diagnostic UI only; this is not the final BaseOS game launcher.
 * Reads Linux evdev and redraws a text menu on framebuffer console tty1.
 */
#define _DEFAULT_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#define MAX_INPUTS 64
#define PATH_LEN 256
#define NAME_LEN 128

enum input_role { ROLE_OTHER = 0, ROLE_GAME, ROLE_FUNCTION, ROLE_STICK, ROLE_VOLUME, ROLE_POWER };
enum screen_id { SCREEN_HOME = 0, SCREEN_CONTROLS, SCREEN_AUDIO, SCREEN_WIFI, SCREEN_SYSTEM, SCREEN_HELP };

struct input_device {
    int fd;
    enum input_role role;
    char path[PATH_LEN];
    char name[NAME_LEN];
};

static struct input_device inputs[MAX_INPUTS];
static int input_count;
static volatile sig_atomic_t running = 1;
static int current_screen = SCREEN_HOME;
static int selected_item;
static int event_count;
static int function_count;
static int key_count;
static int axis_x = 511, axis_y = 511, axis_rx = 511, axis_ry = 511;
static int joy_y_direction;
static char last_event[160] = "Waiting for controller input...";
static struct termios saved_termios;
static int termios_saved;
static long long power_press_start_ms = -1;

static const char *menu_items[] = {
    "Controller / live input monitor",
    "Audio device inventory",
    "Wi-Fi status",
    "System and power information",
    "Control mapping help",
    "Linux command-line shell (root)"
};
#define MENU_COUNT ((int)(sizeof(menu_items) / sizeof(menu_items[0])))

static long long monotonic_ms(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
        return 0;
    return ts.tv_sec * 1000LL + ts.tv_nsec / 1000000LL;
}

static void stop_running(int sig)
{
    (void)sig;
    running = 0;
}

static enum input_role role_for_name(const char *name)
{
    if (strstr(name, "gpio-keys-control") != NULL) return ROLE_GAME;
    if (strstr(name, "adc-keys") != NULL) return ROLE_FUNCTION;
    if (strstr(name, "adc-joystick") != NULL) return ROLE_STICK;
    if (strstr(name, "gpio-keys-vol") != NULL) return ROLE_VOLUME;
    if (strcmp(name, "rk805 pwrkey") == 0) return ROLE_POWER;
    return ROLE_OTHER;
}

static void discover_inputs(void)
{
    DIR *dir = opendir("/dev/input");
    struct dirent *entry;
    input_count = 0;
    if (dir == NULL) return;

    while ((entry = readdir(dir)) != NULL && input_count < MAX_INPUTS) {
        struct input_device *dev;
        char path[PATH_LEN];
        char name[NAME_LEN] = "unknown input";
        int fd;

        if (strncmp(entry->d_name, "event", 5) != 0) continue;
        if (snprintf(path, sizeof(path), "/dev/input/%s", entry->d_name) >= (int)sizeof(path)) continue;
        fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
        if (fd < 0) continue;
        if (ioctl(fd, EVIOCGNAME(sizeof(name)), name) < 0) {
            (void)close(fd);
            continue;
        }

        dev = &inputs[input_count++];
        dev->fd = fd;
        dev->role = role_for_name(name);
        (void)snprintf(dev->path, sizeof(dev->path), "%s", path);
        (void)snprintf(dev->name, sizeof(dev->name), "%s", name);
    }
    (void)closedir(dir);
}

static const char *key_name(unsigned int code)
{
    switch (code) {
    case BTN_DPAD_UP: return "DPAD UP";
    case BTN_DPAD_DOWN: return "DPAD DOWN";
    case BTN_DPAD_LEFT: return "DPAD LEFT";
    case BTN_DPAD_RIGHT: return "DPAD RIGHT";
    case BTN_SOUTH: return "B (bottom / BTN_SOUTH)";
    case BTN_EAST: return "A (right / BTN_EAST)";
    case BTN_WEST: return "Y (left / BTN_WEST)";
    case BTN_NORTH: return "X (top / BTN_NORTH)";
    case KEY_POWER: return "POWER";
    case BTN_TL: return "L1 / TL";
    case BTN_TR: return "R1 / TR";
    case BTN_TL2: return "L2 / TL2";
    case BTN_TR2: return "R2 / TR2";
    case BTN_THUMBL: return "L3 / THUMBL";
    case BTN_THUMBR: return "R3 / THUMBR";
    case BTN_SELECT: return "SELECT";
    case BTN_START: return "START";
    case KEY_F1: return "F1";
    case KEY_F2: return "F2";
    case KEY_ESC: return "ESC";
    case KEY_ENTER: return "ENTER";
    case KEY_VOLUMEUP: return "VOLUME UP";
    case KEY_VOLUMEDOWN: return "VOLUME DOWN";
    default: return NULL;
    }
}

static int read_value(const char *path, char *dst, size_t dst_len)
{
    FILE *fp;
    size_t len;
    if (dst_len == 0) return 0;
    dst[0] = '\0';
    fp = fopen(path, "r");
    if (fp == NULL) {
        (void)snprintf(dst, dst_len, "unavailable");
        return 0;
    }
    if (fgets(dst, (int)dst_len, fp) == NULL) {
        (void)snprintf(dst, dst_len, "unavailable");
        (void)fclose(fp);
        return 0;
    }
    (void)fclose(fp);
    len = strlen(dst);
    while (len > 0 && (dst[len - 1] == '\n' || dst[len - 1] == '\r' || dst[len - 1] == '\0'))
        dst[--len] = '\0';
    return 1;
}

static void print_file(const char *path, int max_lines, int *row)
{
    FILE *fp;
    char line[160];
    int count = 0;
    fp = fopen(path, "r");
    if (fp == NULL) {
        printf("\033[%d;3H  %s: unavailable\n", *row, path);
        ++(*row);
        return;
    }
    while (count < max_lines && *row < 27 && fgets(line, sizeof(line), fp) != NULL) {
        size_t len = strlen(line);
        while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r'))
            line[--len] = '\0';
        printf("\033[%d;3H  %-74.74s\n", *row, line);
        ++(*row);
        ++count;
    }
    (void)fclose(fp);
}

static void render_header(const char *title)
{
    printf("\033[2J\033[H\033[?25l");
    printf("\033[1;36m+------------------------------------------------------------------------------+\033[0m\n");
    printf("\033[1;36m| %-76.76s |\033[0m\n", title);
    printf("\033[1;36m+------------------------------------------------------------------------------+\033[0m\n");
}

static void render_home(void)
{
    char operstate[64], battery[64];
    render_header("BaseOS RG353PS  |  Interactive hardware bring-up");
    (void)read_value("/sys/class/net/wlan0/operstate", operstate, sizeof(operstate));
    (void)read_value("/sys/class/power_supply/battery/capacity", battery, sizeof(battery));

    printf("\n  This is a controller-responsive diagnostic menu, not the final game UI.\n\n");
    printf("  D-pad UP/DOWN or left stick selects; A (right / BTN_EAST) opens.\n");
    printf("  B (bottom / BTN_SOUTH) returns. FUNCTION toggles the live input monitor.\n\n");
    printf("  \033[1;33mMENU\033[0m\n");
    for (int i = 0; i < MENU_COUNT; ++i) {
        if (i == selected_item) printf("  \033[1;32m > %-70.70s\033[0m\n", menu_items[i]);
        else printf("    %-70.70s\n", menu_items[i]);
    }
    printf("\n  Input devices: %d     Button events: %d     Function presses: %d\n",
           input_count, key_count, function_count);
    printf("  Wi-Fi: %-12.12s     Battery: %-5.5s%%\n", operstate, battery);
    printf("  Last input: %-68.68s\n", last_event);
    printf("  Volume +/- keys adjust RK817 playback level.\n");
    printf("  Short Power press shows system information.\n");
    printf("  Hold Power for 2 seconds to shut down cleanly.\n");
    printf("\n  Select the Linux command-line shell menu entry to run commands/scripts.\n");
    printf("  Serial console remains available on ttyS2 for shell/debug access.\n");
}

static void render_controls(void)
{
    render_header("Controller monitor  |  live evdev input");
    printf("\n  DEVICE MAPPING\n");
    printf("    Game controls : gpio-keys-control\n");
    printf("    Function key  : adc-keys\n");
    printf("    Analog sticks : adc-joystick\n");
    printf("\n  BUTTONS (raw Linux input event names)\n");
    printf("    D-pad: BTN_DPAD_UP / DOWN / LEFT / RIGHT\n");
    printf("    Nintendo layout: A=right (BTN_EAST), B=bottom (BTN_SOUTH)\n");
    printf("    X=top (BTN_NORTH), Y=left (BTN_WEST)\n");
    printf("    Extra: BTN_TL / TR / TL2 / TR2 / THUMBL / THUMBR / START / SELECT\n");
    printf("    Function: %s\n", function_count > 0 ? "detected" : "press Function to test");
    printf("\n  ANALOG AXES (expected idle around 511; observed range 15..1023)\n");
    printf("    L X=%4d  Y=%4d      R X=%4d  Y=%4d\n", axis_x, axis_y, axis_rx, axis_ry);
    printf("\n  LAST EVENT\n");
    printf("    \033[1;33m%-72.72s\033[0m\n", last_event);
    printf("\n  Counters: game key-downs=%d   function key-downs=%d   all input events=%d\n",
           key_count, function_count, event_count);
    printf("\n  B (bottom / BTN_SOUTH) returns. FUNCTION toggles the monitor.\n");
}

static void render_audio(void)
{
    int row = 7;
    render_header("Audio diagnostics");
    printf("\n  ALSA card enumeration (this screen does not play any sound):\n");
    print_file("/proc/asound/cards", 5, &row);
    ++row;
    printf("\033[%d;3HPCM devices:\n", row++);
    print_file("/proc/asound/pcm", 6, &row);
    printf("\n  Volume +/- keys adjust RK817 Master Playback Volume by 5%%.\n");
    printf("  Serial shell: amixer -c 1 get Master\n");
    printf("  No sound is played automatically.\n");
    printf("\n  B (bottom / BTN_SOUTH) returns to menu.\n");
}

static void render_wifi(void)
{
    char value[128];
    int row = 11;
    render_header("Wi-Fi diagnostics");
    (void)read_value("/sys/class/net/wlan0/operstate", value, sizeof(value));
    printf("\n  Interface state: %s\n", value);
    (void)read_value("/sys/class/net/wlan0/address", value, sizeof(value));
    printf("  MAC address:     %s\n", value);
    (void)read_value("/sys/class/rfkill/rfkill0/state", value, sizeof(value));
    printf("  rfkill WLAN state (1=unblocked): %s\n", value);
    printf("\n  Kernel wireless status:\n");
    print_file("/proc/net/wireless", 5, &row);
    printf("\n  No access point association is started by this screen.\n");
    printf("  Serial shell: iw dev\n");
    printf("\n  B (bottom / BTN_SOUTH) returns to menu.\n");
}

static void render_system(void)
{
    char value[128];
    int row = 15;
    render_header("System and power information");
    (void)read_value("/proc/device-tree/model", value, sizeof(value));
    printf("\n  Device: %s\n", value);
    (void)read_value("/proc/uptime", value, sizeof(value));
    printf("  Uptime: %s seconds\n", value);
    (void)read_value("/sys/class/power_supply/battery/status", value, sizeof(value));
    printf("  Battery status: %s\n", value);
    (void)read_value("/sys/class/power_supply/battery/capacity", value, sizeof(value));
    printf("  Battery capacity: %s%%\n", value);
    (void)read_value("/sys/class/thermal/thermal_zone0/temp", value, sizeof(value));
    printf("  CPU temperature: %s millidegrees C\n", value);
    printf("\n  Memory summary:\n");
    print_file("/proc/meminfo", 4, &row);
    printf("\n  B (bottom / BTN_SOUTH) returns to menu.\n");
}

static void render_help(void)
{
    render_header("Control mapping help");
    printf("\n  D-pad UP/DOWN     Move menu selection\n");
    printf("  Left stick UP/DOWN also moves selection when crossing the dead zone\n");
    printf("  A on the right (BTN_EAST)  Select/open an item\n");
    printf("  B at the bottom (BTN_SOUTH) Back to the main menu\n");
    printf("  Volume +/-        Adjust RK817 playback volume\n");
    printf("  Power button      Short press opens system information\n");
    printf("  FUNCTION          Toggle the live controller monitor\n");
    printf("\n  This step verifies physical-to-kernel input mapping and screen response.\n");
    printf("  Select \"Linux command-line shell\" to run commands and scripts.\n");
    printf("  The shell runs as root; type exit to return to this frontend.\n");
    printf("  Emulation hotkeys, ROM browsing and game launching are not implemented.\n");
    printf("\n  B (bottom / BTN_SOUTH) returns to menu.\n");
}

static void render(void)
{
    switch (current_screen) {
    case SCREEN_CONTROLS: render_controls(); break;
    case SCREEN_AUDIO: render_audio(); break;
    case SCREEN_WIFI: render_wifi(); break;
    case SCREEN_SYSTEM: render_system(); break;
    case SCREEN_HELP: render_help(); break;
    case SCREEN_HOME:
    default: render_home(); break;
    }
    if (current_screen != SCREEN_HOME && current_screen != SCREEN_CONTROLS)
        printf("\n  Last input: %-68.68s\n", last_event);
    fflush(stdout);
}

static void navigate_menu(int delta)
{
    selected_item += delta;
    if (selected_item < 0) selected_item = MENU_COUNT - 1;
    if (selected_item >= MENU_COUNT) selected_item = 0;
    if (current_screen == SCREEN_HOME) render();
}

static void launch_shell(void)
{
    pid_t child;
    int status = 0;
    int wait_ok = 1;

    if (termios_saved &&
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved_termios) != 0) {
        (void)snprintf(last_event, sizeof(last_event),
                       "Warning: could not restore terminal mode before shell");
    }

    (void)printf("\033[0m\033[?25h\033[2J\033[H");
    (void)printf("BaseOS RG353PS command-line shell (root)\n");
    (void)printf("Type 'exit' to return to the diagnostic frontend.\n");
    (void)printf("To run a script: sh /path/to/script.sh\n");
    (void)printf("Be careful: commands run with root privileges.\n\n");
    fflush(stdout);

    if (!isatty(STDIN_FILENO)) {
        (void)snprintf(last_event, sizeof(last_event),
                       "Shell unavailable: frontend stdin is not a TTY");
        current_screen = SCREEN_HOME;
        render();
        return;
    }

    child = fork();
    if (child < 0) {
        (void)snprintf(last_event, sizeof(last_event),
                       "Could not start shell: %s", strerror(errno));
    } else if (child == 0) {
        /* The frontend handles signals to exit its event loop.
         * The interactive shell must receive normal terminal signals. */
        (void)signal(SIGINT, SIG_DFL);
        (void)signal(SIGTERM, SIG_DFL);
        (void)signal(SIGHUP, SIG_DFL);
        (void)signal(SIGQUIT, SIG_DFL);
        (void)signal(SIGTSTP, SIG_DFL);
        execl("/bin/sh", "sh", "-i", (char *)NULL);
        perror("exec /bin/sh");
        _exit(127);
    } else {
        while (waitpid(child, &status, 0) < 0) {
            if (errno == EINTR) continue;
            wait_ok = 0;
            break;
        }
        if (!wait_ok) {
            (void)snprintf(last_event, sizeof(last_event),
                           "Shell ended; waitpid failed: %s", strerror(errno));
        } else if (WIFEXITED(status) && WEXITSTATUS(status) != 0) {
            (void)snprintf(last_event, sizeof(last_event),
                           "Shell exited with status %d", WEXITSTATUS(status));
        } else if (WIFSIGNALED(status)) {
            (void)snprintf(last_event, sizeof(last_event),
                           "Shell terminated by signal %d", WTERMSIG(status));
        } else {
            (void)snprintf(last_event, sizeof(last_event),
                           "Returned from command-line shell");
        }
    }

    /* Restore the frontend's raw input mode after the shell exits. */
    if (termios_saved) {
        struct termios raw = saved_termios;
        raw.c_lflag &= (tcflag_t)~(ICANON | ECHO);
        raw.c_iflag &= (tcflag_t)~(IXON | ICRNL);
        raw.c_cc[VMIN] = 0;
        raw.c_cc[VTIME] = 0;
        (void)tcflush(STDIN_FILENO, TCIFLUSH);
        (void)tcsetattr(STDIN_FILENO, TCSANOW, &raw);
    }
    current_screen = SCREEN_HOME;
    render();
}

static void select_menu_item(void)
{
    switch (selected_item) {
    case 0: current_screen = SCREEN_CONTROLS; break;
    case 1: current_screen = SCREEN_AUDIO; break;
    case 2: current_screen = SCREEN_WIFI; break;
    case 3: current_screen = SCREEN_SYSTEM; break;
    case 4: current_screen = SCREEN_HELP; break;
    case 5:
        launch_shell();
        return;
    default: current_screen = SCREEN_HOME; break;
    }
    render();
}

static void go_back(void)
{
    if (current_screen != SCREEN_HOME) {
        current_screen = SCREEN_HOME;
        render();
    }
}

static int adjust_volume(int volume_up)
{
    pid_t child = fork();
    int status;
    if (child < 0)
        return 0;
    if (child == 0) {
        int nullfd = open("/dev/null", O_WRONLY);
        if (nullfd >= 0) {
            (void)dup2(nullfd, STDOUT_FILENO);
            (void)dup2(nullfd, STDERR_FILENO);
            if (nullfd > STDERR_FILENO)
                (void)close(nullfd);
        }
        execl("/usr/bin/amixer", "amixer", "-c", "1", "set",
              "Master", volume_up ? "5%+" : "5%-", (char *)NULL);
        execl("/usr/sbin/amixer", "amixer", "-c", "1", "set",
              "Master", volume_up ? "5%+" : "5%-", (char *)NULL);
        _exit(127);
    }
    while (waitpid(child, &status, 0) < 0) {
        if (errno == EINTR) continue;
        return 0;
    }
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

static void handle_key_event(struct input_device *dev, const struct input_event *ev)
{
    const char *name = key_name(ev->code);
    char detail[100];
    if (ev->value == 1) {
        ++event_count;
        if (dev->role == ROLE_GAME)
            ++key_count;
    }
    if (name == NULL)
        (void)snprintf(detail, sizeof(detail), "KEY code %u", ev->code);
    else
        (void)snprintf(detail, sizeof(detail), "%s", name);

    if (dev->role == ROLE_FUNCTION) {
        if (ev->value == 1) {
            ++function_count;
            (void)snprintf(last_event, sizeof(last_event), "FUNCTION pressed (%s, code %u)", detail, ev->code);
            current_screen = current_screen == SCREEN_CONTROLS ? SCREEN_HOME : SCREEN_CONTROLS;
            render();
        } else if (ev->value == 0) {
            (void)snprintf(last_event, sizeof(last_event), "FUNCTION released (%s)", detail);
            if (current_screen == SCREEN_CONTROLS) render();
        }
        return;
    }
    if (dev->role == ROLE_VOLUME) {
        if ((ev->value == 1 || ev->value == 2) &&
            (ev->code == KEY_VOLUMEUP || ev->code == KEY_VOLUMEDOWN)) {
            int up = ev->code == KEY_VOLUMEUP;
            int success = adjust_volume(up);
            (void)snprintf(last_event, sizeof(last_event), "Volume %s: %s",
                           up ? "UP" : "DOWN",
                           success ? "RK817 master playback volume changed by 5%"
                                   : "key detected; mixer adjustment failed");
            render();
        }
        return;
    }
    if (dev->role == ROLE_POWER && ev->code == KEY_POWER) {
        if (ev->value == 1) {
            power_press_start_ms = monotonic_ms();
            (void)snprintf(last_event, sizeof(last_event),
                           "POWER pressed: short tap shows system status; hold 2s to shut down");
            current_screen = SCREEN_SYSTEM;
        } else if (ev->value == 0) {
            power_press_start_ms = -1;
            (void)snprintf(last_event, sizeof(last_event), "POWER released before long-press shutdown");
        }
        if (ev->value == 0 || ev->value == 1) render();
        return;
    }
    if (dev->role != ROLE_GAME)
        return;

    (void)snprintf(last_event, sizeof(last_event), "%s %s", detail,
                   ev->value == 0 ? "released" : ev->value == 2 ? "repeating" : "pressed");
    if (ev->value == 1) {
        switch (ev->code) {
        case BTN_DPAD_UP:
            if (current_screen == SCREEN_HOME) { navigate_menu(-1); return; }
            break;
        case BTN_DPAD_DOWN:
            if (current_screen == SCREEN_HOME) { navigate_menu(1); return; }
            break;
        case BTN_EAST: /* Nintendo A, physically at the right. */
            if (current_screen == SCREEN_HOME) { select_menu_item(); return; }
            break;
        case BTN_SOUTH: /* Nintendo B, physically at the bottom. */
            if (current_screen != SCREEN_HOME) { go_back(); return; }
            break;
        default:
            break;
        }
    }
    render();
}

static int joy_direction(int value)
{
    if (value < 270) return 1;
    if (value > 750) return -1;
    return 0;
}

static void handle_axis_event(const struct input_event *ev)
{
    int direction;
    switch (ev->code) {
    case ABS_X: axis_x = ev->value; break;
    case ABS_Y:
        axis_y = ev->value;
        direction = joy_direction(ev->value);
        if (current_screen == SCREEN_HOME && direction != 0 && joy_y_direction == 0)
            navigate_menu(direction);
        joy_y_direction = direction;
        break;
    case ABS_RX: axis_rx = ev->value; break;
    case ABS_RY: axis_ry = ev->value; break;
    default: return;
    }
    ++event_count;
    (void)snprintf(last_event, sizeof(last_event), "AXIS code %u value %d", ev->code, ev->value);
    if (current_screen == SCREEN_CONTROLS) render();
}

static void handle_input(struct input_device *dev)
{
    struct input_event ev;
    ssize_t count;
    while ((count = read(dev->fd, &ev, sizeof(ev))) == (ssize_t)sizeof(ev)) {
        if (ev.type == EV_KEY) handle_key_event(dev, &ev);
        else if (ev.type == EV_ABS && dev->role == ROLE_STICK) handle_axis_event(&ev);
    }
    if (count < 0 && errno != EAGAIN && errno != EINTR) {
        (void)snprintf(last_event, sizeof(last_event), "Read error from %s: %s", dev->name, strerror(errno));
        render();
    }
}

static void handle_keyboard_byte(unsigned char ch, int *escape_state)
{
    if (*escape_state == 1) {
        *escape_state = ch == '[' ? 2 : 0;
        return;
    }
    if (*escape_state == 2) {
        *escape_state = 0;
        if (ch == 'A') navigate_menu(-1);
        else if (ch == 'B') navigate_menu(1);
        else if ((ch == 'C' || ch == 'D') && current_screen != SCREEN_HOME) go_back();
        return;
    }
    if (ch == 27) *escape_state = 1;
    else if (ch == 'q' || ch == 'Q') go_back();
    else if (ch == 'f' || ch == 'F') {
        current_screen = current_screen == SCREEN_CONTROLS ? SCREEN_HOME : SCREEN_CONTROLS;
        render();
    } else if (ch == '\n' || ch == '\r' || ch == ' ') {
        if (current_screen == SCREEN_HOME) select_menu_item();
        else go_back();
    } else if (ch == 'w' || ch == 'W') navigate_menu(-1);
    else if (ch == 's' || ch == 'S') navigate_menu(1);
}

int main(void)
{
    struct pollfd pollfds[MAX_INPUTS + 1];
    int stdin_active = 0;
    int escape_state = 0;

    (void)signal(SIGINT, stop_running);
    (void)signal(SIGTERM, stop_running);
    (void)signal(SIGHUP, stop_running);
    discover_inputs();

    if (isatty(STDIN_FILENO) && tcgetattr(STDIN_FILENO, &saved_termios) == 0) {
        struct termios raw = saved_termios;
        raw.c_lflag &= (tcflag_t)~(ICANON | ECHO);
        raw.c_iflag &= (tcflag_t)~(IXON | ICRNL);
        raw.c_cc[VMIN] = 0;
        raw.c_cc[VTIME] = 0;
        if (tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0) termios_saved = 1;
        stdin_active = 1;
    }

    (void)printf("\033[?25l");
    render();
    while (running) {
        int nfds = 0;
        int rc;

        if (stdin_active) {
            pollfds[nfds].fd = STDIN_FILENO;
            pollfds[nfds].events = POLLIN;
            pollfds[nfds].revents = 0;
            ++nfds;
        }
        for (int i = 0; i < input_count; ++i) {
            pollfds[nfds].fd = inputs[i].fd;
            pollfds[nfds].events = POLLIN;
            pollfds[nfds].revents = 0;
            ++nfds;
        }

        {
            int timeout = nfds == 0 ? 1000 : -1;
            if (power_press_start_ms >= 0) {
                long long left = 2000 - (monotonic_ms() - power_press_start_ms);
                timeout = left > 0 ? (int)left : 0;
            }
            rc = poll(pollfds, (nfds_t)nfds, timeout);
        }
        if (rc < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (power_press_start_ms >= 0 &&
            monotonic_ms() - power_press_start_ms >= 2000) {
            power_press_start_ms = -1;
            sync();
            execl("/sbin/poweroff", "poweroff", (char *)NULL);
            (void)snprintf(last_event, sizeof(last_event),
                           "Clean shutdown command failed; inspect /sbin/poweroff");
            current_screen = SCREEN_SYSTEM;
            render();
        }
        if (rc == 0) continue;

        {
            int index = 0;
            if (stdin_active) {
                if ((pollfds[0].revents & POLLIN) != 0) {
                    unsigned char bytes[32];
                    ssize_t n = read(STDIN_FILENO, bytes, sizeof(bytes));
                    for (ssize_t i = 0; i < n; ++i) handle_keyboard_byte(bytes[i], &escape_state);
                }
                index = 1;
            }
            for (int i = 0; i < input_count; ++i) {
                if (inputs[i].fd >= 0 && (pollfds[index + i].revents & POLLIN) != 0)
                    handle_input(&inputs[i]);
                if (inputs[i].fd >= 0 &&
                    (pollfds[index + i].revents & (POLLHUP | POLLERR | POLLNVAL)) != 0) {
                    (void)close(inputs[i].fd);
                    inputs[i].fd = -1;
                }
            }
        }
    }

    if (termios_saved) (void)tcsetattr(STDIN_FILENO, TCSANOW, &saved_termios);
    (void)printf("\033[0m\033[?25h\n");
    fflush(stdout);
    for (int i = 0; i < input_count; ++i)
        if (inputs[i].fd >= 0) (void)close(inputs[i].fd);
    return 0;
}
