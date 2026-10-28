#include <sys/socket.h>
#include <netdb.h>
#include <errno.h>

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { \
        const void *replacement; \
        const void *replacee; \
    } _interpose_##_replacee \
    __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(unsigned long)&_replacement, \
        (const void *)(unsigned long)&_replacee \
    };

static int my_connect(int socket, const struct sockaddr *address, socklen_t address_len) {
    errno = ENETUNREACH;
    return -1;
}
DYLD_INTERPOSE(my_connect, connect);

static int my_socket(int domain, int type, int protocol) {
    errno = EACCES;
    return -1;
}
DYLD_INTERPOSE(my_socket, socket);

static int my_getaddrinfo(const char *node, const char *service,
                          const struct addrinfo *hints,
                          struct addrinfo **res) {
    return EAI_NODATA;
}
DYLD_INTERPOSE(my_getaddrinfo, getaddrinfo);
