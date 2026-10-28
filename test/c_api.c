/*
 * include/dateparsa.h from C: `zig build test` builds this against the
 * static library and runs it. Each check prints what it expected when it
 * fails, and the exit status is the number that failed.
 */
#include <stdio.h>
#include <string.h>

#include "dateparsa.h"

static int failures = 0;

#define CHECK(cond)                                                        \
    do {                                                                   \
        if (!(cond)) {                                                     \
            fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, \
                    #cond);                                                \
            failures++;                                                    \
        }                                                                  \
    } while (0)

#define S(lit) lit, sizeof(lit) - 1

static int same(const char *p, size_t n, const char *want) {
    return n == strlen(want) && memcmp(p, want, n) == 0;
}

static void quick_start(void) {
    dateparsa_result r;
    CHECK(dateparsa_parse(S("2024-03-15T10:30:00Z"), NULL, &r) == DATEPARSA_OK);
    CHECK(r.time.year == 2024 && r.time.month == 3 && r.time.day == 15);
    CHECK(r.time.hour == 10 && r.time.minute == 30 && r.time.offset_seconds == 0);
    CHECK(r.unix_seconds == 1710498600);
    CHECK(r.kind == DATEPARSA_KIND_ABSOLUTE && !r.ambiguous && r.reusable);
    CHECK(same(r.label, r.label_len, "ISO8601_DATETIME_Z"));
}

static void readme_example(void) {
    dateparsa_result r;
    if (dateparsa_parse("2024-03-15 10:30:00", 19, NULL, &r) == DATEPARSA_OK) {
        // r.time.year 2024, r.unix_seconds 1710498600, "%.*s" of r.label: SQL_DATETIME
        dateparsa_datetime next = {0};
        if (r.reusable)
            dateparsa_layout_parse(&r.layout, "2024-04-20 08:00:00", 19, &next); // no detection
        CHECK(r.time.year == 2024 && r.unix_seconds == 1710498600);
        CHECK(same(r.label, r.label_len, "SQL_DATETIME"));
        CHECK(r.reusable && next.month == 4 && next.day == 20 && next.hour == 8);
    } else {
        CHECK(!"the README's example parses");
    }
}

static void reuse_the_layout(void) {
    dateparsa_result first;
    dateparsa_datetime t;
    size_t n = 0;
    CHECK(dateparsa_parse(S("2024-03-15"), NULL, &first) == DATEPARSA_OK);
    CHECK(dateparsa_layout_reusable(&first.layout));
    CHECK(dateparsa_layout_parse(&first.layout, S(" 2024-03-16 "), &t) == DATEPARSA_OK);
    CHECK(t.year == 2024 && t.day == 16);
    CHECK(dateparsa_layout_parse(&first.layout, S("March 17, 2024"), &t) == DATEPARSA_NO_MATCH);
    /* The label first: C leaves the order of a call's arguments open. */
    const char *label = dateparsa_layout_label(&first.layout, &n);
    CHECK(same(label, n, "ISO8601_DATE"));

    dateparsa_layout detected;
    CHECK(dateparsa_detect(S("15.03.2024"), NULL, &detected) == DATEPARSA_OK);
    CHECK(dateparsa_layout_parse(&detected, S("16.04.2025"), &t) == DATEPARSA_OK);
    CHECK(t.year == 2025 && t.month == 4 && t.day == 16);

    /* A layout copies like any struct. */
    dateparsa_layout copy;
    memcpy(&copy, &first.layout, sizeof copy);
    CHECK(dateparsa_layout_parse(&copy, S("2024-12-31"), &t) == DATEPARSA_OK);
}

static void parse_a_column(void) {
    const char *column[] = {"2024-01-01", "2024-06-15", "March 3, 2024", "2024-12-31"};
    dateparsa_parser p;
    dateparsa_result r;
    CHECK(dateparsa_parser_init(&p, NULL) == DATEPARSA_OK);
    for (size_t i = 0; i < sizeof column / sizeof column[0]; i++) {
        CHECK(dateparsa_parser_parse(&p, column[i], strlen(column[i]), &r) == DATEPARSA_OK);
        CHECK(r.time.year == 2024);
    }
    dateparsa_parser_reset(&p);
    CHECK(dateparsa_parser_parse(&p, S("nonsense"), &r) == DATEPARSA_NO_MATCH);
}

static void ambiguity(void) {
    dateparsa_result r;
    CHECK(dateparsa_parse(S("01/02/2024"), NULL, &r) == DATEPARSA_OK);
    CHECK(r.ambiguous && r.time.month == 1);

    dateparsa_options eu = {0};
    eu.prefer_day_first = true;
    CHECK(dateparsa_parse(S("01/02/2024"), &eu, &r) == DATEPARSA_OK);
    CHECK(r.time.month == 2);

    dateparsa_diagnostics diag;
    dateparsa_options strict = {0};
    strict.strict = true;
    strict.diagnostics = &diag;
    CHECK(dateparsa_parse(S("01/02/2024"), &strict, &r) == DATEPARSA_AMBIGUOUS);
    CHECK(diag.interpretation_count == 2);
    CHECK(same(diag.interpretations[0].label, diag.interpretations[0].label_len, "MM/DD/YYYY"));
    CHECK(same(diag.interpretations[1].label, diag.interpretations[1].label_len, "DD/MM/YYYY"));
    CHECK(diag.interpretations[1].time.month == 2);
}

static void natural_language(void) {
    dateparsa_datetime base = {2024, 3, 15, 12, 0, 0, 0, 0};
    dateparsa_options o = {0};
    dateparsa_diagnostics diag;
    dateparsa_result r;
    o.diagnostics = &diag;
    CHECK(dateparsa_parse(S("3 days ago"), &o, &r) == DATEPARSA_NO_BASE_TIME);
    CHECK(diag.message_len > 0);

    o.base_time = &base;
    CHECK(dateparsa_parse(S("next friday at 5pm"), &o, &r) == DATEPARSA_OK);
    CHECK(r.time.day == 22 && r.time.hour == 17);
    CHECK(r.kind == DATEPARSA_KIND_RELATIVE && !r.reusable);
    CHECK(same(r.label, r.label_len, "NATURAL_LANGUAGE"));
}

static void locales(void) {
    uint32_t compiled = dateparsa_locales_compiled();
    uint32_t bit = 0;
    CHECK(compiled & DATEPARSA_LOCALE_EN);
    CHECK(dateparsa_locale_lookup(S("xx"), &bit) == DATEPARSA_NO_MATCH);
    if (!(compiled & DATEPARSA_LOCALE_FR)) return;

    CHECK(dateparsa_locale_lookup(S("fr-CA"), &bit) == DATEPARSA_OK);
    CHECK(bit == DATEPARSA_LOCALE_FR);
    dateparsa_options o = {0};
    dateparsa_result r;
    o.locales = bit;
    CHECK(dateparsa_parse(S("15 mars 2024"), &o, &r) == DATEPARSA_OK);
    CHECK(r.time.month == 3);
    CHECK(dateparsa_parse(S("15 mars 2024"), NULL, &r) == DATEPARSA_NO_MATCH);
}

static void zones_and_timestamps(void) {
    dateparsa_options o = {0};
    dateparsa_result r;
    o.timezone_offset = 5 * 3600 + 30 * 60;
    CHECK(dateparsa_parse(S("2024-03-15 10:30:00"), &o, &r) == DATEPARSA_OK);
    CHECK(r.time.offset_seconds == 19800 && r.unix_seconds == 1710478800);

    CHECK(dateparsa_parse(S("1710504800123"), NULL, &r) == DATEPARSA_OK);
    CHECK(r.time.nanosecond == 123000000 && !r.reusable);
    CHECK(same(r.label, r.label_len, "UNIX_TIMESTAMP"));
}

static void format(void) {
    dateparsa_datetime t = {2024, 3, 15, 12, 30, 0, 123000000, -5 * 3600};
    char buf[DATEPARSA_RFC3339_MAX];
    size_t n = 0;
    int64_t s = 0;
    CHECK(dateparsa_format_rfc3339(&t, buf, sizeof buf, &n) == DATEPARSA_OK);
    CHECK(strcmp(buf, "2024-03-15T12:30:00.123-05:00") == 0 && n == strlen(buf));
    CHECK(dateparsa_format_rfc3339(&t, buf, n, &n) == DATEPARSA_BUFFER_TOO_SMALL);
    CHECK(dateparsa_to_unix(&t, &s) == DATEPARSA_OK && s == 1710523800);

    dateparsa_datetime widest = {-2147483647 - 1, 12, 31, 23, 59, 59, 999999999, -86399};
    CHECK(dateparsa_format_rfc3339(&widest, buf, sizeof buf, &n) == DATEPARSA_OK);
    CHECK(strcmp(buf, "-2147483648-12-31T23:59:59.999999999-23:59") == 0);
}

static void bad_arguments(void) {
    dateparsa_datetime feb30 = {2024, 2, 30, 0, 0, 0, 0, 0};
    dateparsa_datetime far = {1000000000, 1, 1, 0, 0, 0, 0, 0};
    dateparsa_options o = {0};
    dateparsa_diagnostics diag;
    dateparsa_result r;
    dateparsa_datetime t;
    o.diagnostics = &diag;

    CHECK(dateparsa_parse(S("2024-03-15"), &o, NULL) == DATEPARSA_INVALID_ARGUMENT);
    CHECK(dateparsa_parse(NULL, 3, &o, &r) == DATEPARSA_INVALID_ARGUMENT);
    CHECK(dateparsa_parse(NULL, 0, &o, &r) == DATEPARSA_NO_MATCH);
    o.base_time = &feb30;
    CHECK(dateparsa_parse(S("today"), &o, &r) == DATEPARSA_INVALID_ARGUMENT);
    CHECK(same(diag.message, diag.message_len, "base_time is not a valid date and time"));
    o.base_time = &far;
    CHECK(dateparsa_parse(S("today"), &o, &r) == DATEPARSA_INVALID_ARGUMENT);
    o.base_time = NULL;
    o.timezone_offset = 86400;
    CHECK(dateparsa_parse(S("2024-03-15"), &o, &r) == DATEPARSA_INVALID_ARGUMENT);
    o.timezone_offset = 0;
    o.locales = 1u << 20;
    CHECK(dateparsa_parse(S("2024-03-15"), &o, &r) == DATEPARSA_INVALID_ARGUMENT);

    /* A layout or parser the library never filled in is refused, not read. */
    dateparsa_layout zeroed;
    dateparsa_parser unset;
    memset(&zeroed, 0, sizeof zeroed);
    memset(&unset, 0, sizeof unset);
    CHECK(dateparsa_layout_parse(&zeroed, S("2024-03-15"), &t) == DATEPARSA_INVALID_ARGUMENT);
    CHECK(!dateparsa_layout_reusable(&zeroed));
    CHECK(dateparsa_parser_parse(&unset, S("2024-03-15"), &r) == DATEPARSA_INVALID_ARGUMENT);
    CHECK(dateparsa_format_rfc3339(&feb30, NULL, 0, NULL) == DATEPARSA_INVALID_ARGUMENT);
}

int main(void) {
    const char *version = dateparsa_version();
    CHECK(version != NULL && strlen(version) >= 5);

    quick_start();
    readme_example();
    reuse_the_layout();
    parse_a_column();
    ambiguity();
    natural_language();
    locales();
    zones_and_timestamps();
    format();
    bad_arguments();

    if (failures != 0) fprintf(stderr, "%d checks failed\n", failures);
    return failures;
}
