/* Windows-only build shim (not part of upstream libmdb): stdout/stderr in binary mode, so the tools
 * write the same bytes as on Linux (LF line ends; CR/LF inside memo fields is not doubled). */
#include <fcntl.h>
#include <io.h>

__attribute__((constructor)) static void mdb_win_binary_stdio(void) {
    _setmode(1, _O_BINARY);
    _setmode(2, _O_BINARY);
}
