#include <sys/socket.h>
#include <errno.h>

__attribute__((visibility("default"))) 
int connect(int socket, const struct sockaddr *address, socklen_t address_len) {
    errno = ENETUNREACH;
    return -1;
}

__attribute__((visibility("default"))) 
int socket(int domain, int type, int protocol) {
    errno = EACCES;
    return -1;
}
