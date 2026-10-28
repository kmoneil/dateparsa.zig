// include/dateparsa.h as C++ sees it: it has to compile, and its opaque
// types have to be the sizes it says. `zig build test` compiles this.
#include "dateparsa.h"

static_assert(sizeof(dateparsa_layout) == DATEPARSA_LAYOUT_SIZE, "layout size");
static_assert(sizeof(dateparsa_parser) == DATEPARSA_PARSER_SIZE, "parser size");

int dateparsa_header_compiles_as_cpp() {
    dateparsa_options o = {};
    dateparsa_result r;
    return dateparsa_parse("2024-03-15", 10, &o, &r) == DATEPARSA_OK;
}
