// set_fmt.c - set a V4L2 format from a raw fourcc and print the driver's answer
// (incl. bytesperline, which the Pi 5 launchers use as the decoder stride).
// 'RGGB' is the standard V4L2_PIX_FMT_SRGGB8 fourcc.
//
// usage: ./set_fmt <mode> /dev/videoN width height fourcc(4 chars)
//   mode 0 = V4L2_BUF_TYPE_VIDEO_CAPTURE (pixel format)
//   mode 1 = V4L2_BUF_TYPE_META_CAPTURE  (metadata dataformat)
// e.g. ./set_fmt 0 /dev/video0 100 38 RGGB
//      ./set_fmt 1 /dev/video0 100 38 SENS
//
// build on the Pi: gcc -o set_fmt set_fmt.c

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/videodev2.h>

/* v4l2_meta_format gained width/height with the generic metadata formats
 * (Linux 6.10 uapi). Older userspace headers (e.g. Debian bookworm's 6.1
 * linux-libc-dev) lack them; the video mode used by the launchers still works. */
#ifdef V4L2_META_FMT_GENERIC_8
#define HAVE_META_WH 1
#endif

int main(int argc, char **argv)
{
	if (argc != 6 || strlen(argv[5]) != 4) {
		fprintf(stderr,
			"usage: %s <0=video|1=meta> /dev/videoN width height fourcc(4chars)\n",
			argv[0]);
		return 1;
	}

	int meta = atoi(argv[1]) == 1;
	int fd = open(argv[2], O_RDWR);
	if (fd < 0) {
		perror("open");
		return 1;
	}

	struct v4l2_format f;
	memset(&f, 0, sizeof(f));
	f.type = meta ? V4L2_BUF_TYPE_META_CAPTURE : V4L2_BUF_TYPE_VIDEO_CAPTURE;

	if (meta) {
#ifdef HAVE_META_WH
		f.fmt.meta.width = atoi(argv[3]);
		f.fmt.meta.height = atoi(argv[4]);
#else
		fprintf(stderr, "meta mode needs >= 6.10 uapi headers; rebuild with newer linux-libc-dev\n");
		close(fd);
		return 1;
#endif
		f.fmt.meta.dataformat = v4l2_fourcc(argv[5][0], argv[5][1],
						 argv[5][2], argv[5][3]);
	} else {
		f.fmt.pix.width = atoi(argv[3]);
		f.fmt.pix.height = atoi(argv[4]);
		f.fmt.pix.pixelformat = v4l2_fourcc(argv[5][0], argv[5][1],
						 argv[5][2], argv[5][3]);
	}

	if (ioctl(fd, VIDIOC_S_FMT, &f)) {
		perror("VIDIOC_S_FMT");
		close(fd);
		return 1;
	}

	memset(&f, 0, sizeof(f));
	f.type = meta ? V4L2_BUF_TYPE_META_CAPTURE : V4L2_BUF_TYPE_VIDEO_CAPTURE;
	if (ioctl(fd, VIDIOC_G_FMT, &f)) {
		perror("VIDIOC_G_FMT");
		close(fd);
		return 1;
	}

	if (meta)
#ifdef HAVE_META_WH
		printf("now: %u x %u dataformat=%c%c%c%c buffersize=%u\n",
		       f.fmt.meta.width, f.fmt.meta.height,
		       (char)(f.fmt.meta.dataformat & 0xff),
		       (char)((f.fmt.meta.dataformat >> 8) & 0xff),
		       (char)((f.fmt.meta.dataformat >> 16) & 0xff),
		       (char)((f.fmt.meta.dataformat >> 24) & 0xff),
		       f.fmt.meta.buffersize);
#else
		;
#endif
	else
		printf("now: %u x %u pixelformat=%c%c%c%c bpl=%u sizeimage=%u\n",
		       f.fmt.pix.width, f.fmt.pix.height,
		       (char)(f.fmt.pix.pixelformat & 0xff),
		       (char)((f.fmt.pix.pixelformat >> 8) & 0xff),
		       (char)((f.fmt.pix.pixelformat >> 16) & 0xff),
		       (char)((f.fmt.pix.pixelformat >> 24) & 0xff),
		       f.fmt.pix.bytesperline, f.fmt.pix.sizeimage);

	close(fd);
	return 0;
}
