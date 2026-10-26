#ifndef CDISKIO_H
#define CDISKIO_H

#include <stdint.h>

/// DKIOCGETBLOCKSIZE. Returns 0 on success, -1 with errno set on failure.
int xs_disk_block_size(int fd, uint32_t *out);
/// DKIOCGETBLOCKCOUNT.
int xs_disk_block_count(int fd, uint64_t *out);
/// DKIOCSYNCHRONIZE over the whole device: asks the device to commit its
/// write cache to the media.
int xs_disk_synchronize(int fd);

#endif
