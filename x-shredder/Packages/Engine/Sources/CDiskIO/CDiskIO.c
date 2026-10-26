#include "CDiskIO.h"

#include <string.h>
#include <sys/disk.h>
#include <sys/ioctl.h>

int xs_disk_block_size(int fd, uint32_t *out) {
    return ioctl(fd, DKIOCGETBLOCKSIZE, out);
}

int xs_disk_block_count(int fd, uint64_t *out) {
    return ioctl(fd, DKIOCGETBLOCKCOUNT, out);
}

int xs_disk_synchronize(int fd) {
    dk_synchronize_t request;
    memset(&request, 0, sizeof(request));
    return ioctl(fd, DKIOCSYNCHRONIZE, &request);
}
