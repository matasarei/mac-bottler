/* Prints the Windows command line win/cmdline.h builds from its arguments. */
#include <stdio.h>
#include "../../win/cmdline.h"

int main(int argc, char **argv)
{
    char cmd[4096] = "";
    for (int i = 1; i < argc; i++)
        if (append_arg(cmd, sizeof(cmd), argv[i])) return 1;
    printf("%s\n", cmd);
    return 0;
}
