/* GPL-3.0-only. Test-only driver for the real IPC implementation. */
#include "bridge-io.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char **argv)
{
    unsigned char *response;
    size_t length;
    int result;
    if (argc != 4)
        return 2;
    result = overnet_bridge_request(argv[1], argv[2], "SNAPSHOT\n",
                                   (size_t)strtoul(argv[3], NULL, 10), &response, &length);
    if (result < 0)
        return 1;
    if (fwrite(response, 1, length, stdout) != length) {
        free(response);
        return 3;
    }
    free(response);
    return 0;
}
