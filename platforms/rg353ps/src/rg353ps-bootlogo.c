#define _FILE_OFFSET_BITS 64
#define _DEFAULT_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#define BOOT_LOGO_PATH "/mnt/boot/bootlogo.bmp"
#define FALLBACK_LOGO_PATH "/usr/share/baseos/bootlogo.bmp"
#define MAX_BITMAP_DIM 4096U
#define MAX_BITMAP_PIXELS (16U * 1024U * 1024U)

struct bitmap {
    uint32_t width;
    uint32_t height;
    uint8_t *rgb;
};

static uint16_t le16(const uint8_t *p)
{
    return (uint16_t)p[0] | (uint16_t)((uint16_t)p[1] << 8);
}

static uint32_t le32(const uint8_t *p)
{
    return (uint32_t)p[0]
        | ((uint32_t)p[1] << 8)
        | ((uint32_t)p[2] << 16)
        | ((uint32_t)p[3] << 24);
}

static int load_bitmap(const char *path, struct bitmap *out)
{
    FILE *fp = NULL;
    uint8_t header[54];
    uint8_t *row = NULL;
    uint32_t width, height, bpp, offset, row_stride;
    int32_t signed_width, signed_height;
    size_t pixels, rgb_bytes;
    int top_down;

    memset(out, 0, sizeof(*out));
    fp = fopen(path, "rb");
    if (!fp)
        return -1;
    if (fread(header, 1, sizeof(header), fp) != sizeof(header)
        || header[0] != 'B' || header[1] != 'M'
        || le32(header + 14) < 40U
        || le16(header + 26) != 1U
        || (le16(header + 28) != 24U && le16(header + 28) != 32U)
        || le32(header + 30) != 0U) {
        fclose(fp);
        return -1;
    }

    offset = le32(header + 10);
    signed_width = (int32_t)le32(header + 18);
    signed_height = (int32_t)le32(header + 22);
    bpp = le16(header + 28);
    if (signed_width <= 0 || signed_height == 0 || signed_height == INT32_MIN) {
        fclose(fp);
        return -1;
    }
    top_down = signed_height < 0;
    width = (uint32_t)signed_width;
    height = (uint32_t)(top_down ? -signed_height : signed_height);
    pixels = (size_t)width * (size_t)height;
    if (width > MAX_BITMAP_DIM || height > MAX_BITMAP_DIM
        || pixels == 0 || pixels > MAX_BITMAP_PIXELS
        || offset < sizeof(header)) {
        fclose(fp);
        return -1;
    }

    row_stride = (uint32_t)((((uint64_t)width * bpp + 31U) / 32U) * 4U);
    rgb_bytes = pixels * 3U;
    out->rgb = malloc(rgb_bytes);
    row = malloc(row_stride);
    if (!out->rgb || !row) {
        free(out->rgb);
        free(row);
        memset(out, 0, sizeof(*out));
        fclose(fp);
        return -1;
    }

    for (uint32_t y = 0; y < height; ++y) {
        uint32_t file_y = top_down ? y : height - 1U - y;
        uint64_t file_offset = (uint64_t)offset + (uint64_t)file_y * row_stride;
        if (file_offset > (uint64_t)LONG_MAX
            || fseek(fp, (long)file_offset, SEEK_SET) != 0
            || fread(row, 1, row_stride, fp) != row_stride) {
            free(out->rgb);
            free(row);
            memset(out, 0, sizeof(*out));
            fclose(fp);
            return -1;
        }
        for (uint32_t x = 0; x < width; ++x) {
            size_t src = (size_t)x * (bpp / 8U);
            size_t dst = ((size_t)y * width + x) * 3U;
            out->rgb[dst + 0] = row[src + 2];
            out->rgb[dst + 1] = row[src + 1];
            out->rgb[dst + 2] = row[src + 0];
        }
    }

    free(row);
    fclose(fp);
    out->width = width;
    out->height = height;
    return 0;
}

static uint32_t pack_channel(uint8_t value, struct fb_bitfield field)
{
    uint32_t max;
    if (field.length == 0 || field.length > 8)
        return 0;
    max = (1U << field.length) - 1U;
    return (((uint32_t)value * max + 127U) / 255U) << field.offset;
}

static uint32_t pack_pixel(const struct fb_var_screeninfo *var,
                           uint8_t red, uint8_t green, uint8_t blue)
{
    return pack_channel(red, var->red)
        | pack_channel(green, var->green)
        | pack_channel(blue, var->blue);
}

static void store_pixel(uint8_t *dst, uint32_t bpp, uint32_t pixel)
{
    dst[0] = (uint8_t)(pixel & 0xffU);
    if (bpp >= 16U)
        dst[1] = (uint8_t)((pixel >> 8) & 0xffU);
    if (bpp >= 24U)
        dst[2] = (uint8_t)((pixel >> 16) & 0xffU);
    if (bpp >= 32U)
        dst[3] = (uint8_t)((pixel >> 24) & 0xffU);
}

static int paint_bitmap(int fd, const struct bitmap *bmp)
{
    struct fb_var_screeninfo var;
    struct fb_fix_screeninfo fix;
    uint8_t *fb = MAP_FAILED;
    size_t map_len, bytes_per_pixel;
    uint32_t draw_w, draw_h, left, top;
    uint32_t bpp;
    uint64_t lhs, rhs;

    if (ioctl(fd, FBIOGET_VSCREENINFO, &var) < 0
        || ioctl(fd, FBIOGET_FSCREENINFO, &fix) < 0)
        return -1;
    bpp = var.bits_per_pixel;
    if ((bpp != 16U && bpp != 24U && bpp != 32U)
        || var.xres == 0 || var.yres == 0 || fix.line_length == 0)
        return -1;

    bytes_per_pixel = bpp / 8U;
    map_len = fix.smem_len ? (size_t)fix.smem_len
                           : (size_t)fix.line_length * var.yres_virtual;
    if (map_len < (size_t)fix.line_length * var.yres)
        return -1;
    fb = mmap(NULL, map_len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (fb == MAP_FAILED)
        return -1;

    // Fit the custom image inside the active panel, preserving aspect ratio.
    lhs = (uint64_t)var.xres * bmp->height;
    rhs = (uint64_t)var.yres * bmp->width;
    if (lhs <= rhs) {
        draw_w = var.xres;
        draw_h = (uint32_t)((uint64_t)bmp->height * var.xres / bmp->width);
    } else {
        draw_h = var.yres;
        draw_w = (uint32_t)((uint64_t)bmp->width * var.yres / bmp->height);
    }
    if (draw_w == 0) draw_w = 1;
    if (draw_h == 0) draw_h = 1;
    left = (var.xres - draw_w) / 2U;
    top = (var.yres - draw_h) / 2U;

    // Clear letterboxing and any old console text before drawing the logo.
    for (uint32_t y = 0; y < var.yres; ++y) {
        uint8_t *line = fb + (size_t)(y + var.yoffset) * fix.line_length
            + (size_t)var.xoffset * bytes_per_pixel;
        for (uint32_t x = 0; x < var.xres; ++x)
            store_pixel(line + (size_t)x * bytes_per_pixel, bpp,
                        pack_pixel(&var, 0, 0, 0));
    }

    for (uint32_t y = 0; y < draw_h; ++y) {
        uint32_t source_y = (uint32_t)((uint64_t)y * bmp->height / draw_h);
        uint8_t *line = fb + (size_t)(top + y + var.yoffset) * fix.line_length
            + (size_t)(left + var.xoffset) * bytes_per_pixel;
        for (uint32_t x = 0; x < draw_w; ++x) {
            uint32_t source_x = (uint32_t)((uint64_t)x * bmp->width / draw_w);
            size_t src = ((size_t)source_y * bmp->width + source_x) * 3U;
            uint32_t pixel = pack_pixel(&var, bmp->rgb[src],
                                        bmp->rgb[src + 1], bmp->rgb[src + 2]);
            store_pixel(line + (size_t)x * bytes_per_pixel, bpp, pixel);
        }
    }

    (void)msync(fb, map_len, MS_SYNC);
    (void)ioctl(fd, FBIOBLANK, FB_BLANK_UNBLANK);
    var.activate = FB_ACTIVATE_NOW;
    (void)ioctl(fd, FBIOPAN_DISPLAY, &var);
    munmap(fb, map_len);
    return 0;
}

int main(void)
{
    const char *paths[] = { BOOT_LOGO_PATH, FALLBACK_LOGO_PATH };
    struct bitmap bmp;
    int fd = open("/dev/fb0", O_RDWR | O_CLOEXEC);
    int result = -1;

    if (fd < 0)
        return 1;
    for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]); ++i) {
        if (load_bitmap(paths[i], &bmp) != 0)
            continue;
        result = paint_bitmap(fd, &bmp);
        free(bmp.rgb);
        if (result == 0)
            break;
    }
    close(fd);
    if (result != 0)
        fprintf(stderr, "baseos-bootlogo: no usable BMP logo: %s\n", strerror(errno));
    return result == 0 ? 0 : 1;
}
