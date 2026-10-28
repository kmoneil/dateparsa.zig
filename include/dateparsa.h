/*
 * dateparsa: date parsing for input whose format you do not control.
 *
 * The C interface to the Zig library (github.com/kmoneil/dateparsa.zig).
 * Build it with `zig build lib`, which installs libdateparsa and this header
 * under zig-out/.
 *
 * Nothing here allocates, reads a clock, or touches the filesystem. Every
 * struct is the caller's: declare it, pass a pointer, and the call fills it
 * in. A zeroed dateparsa_options is the default: English, UTC for an input
 * that writes no zone, and no base time.
 *
 * Strings are pointer and length and need no terminating NUL. The strings a
 * call hands back (labels, messages) are static, live as long as the
 * library, and are not NUL-terminated either: print one with "%.*s".
 *
 * Every function is safe to call from any thread at once, except that one
 * dateparsa_parser must not be used by two threads at a time.
 */
#ifndef DATEPARSA_H
#define DATEPARSA_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* What every call returns. */
typedef enum dateparsa_status {
    DATEPARSA_OK = 0,
    /* No format, timestamp or natural-language reading fits. */
    DATEPARSA_NO_MATCH = 1,
    /* Strict mode only: more than one reading fits. */
    DATEPARSA_AMBIGUOUS = 2,
    /* The input needs a base time and the options carry none. */
    DATEPARSA_NO_BASE_TIME = 3,
    /* A pointer that must not be NULL was, or a value was out of range.
     * The diagnostics message, when asked for, says which. */
    DATEPARSA_INVALID_ARGUMENT = 4,
    /* The output buffer is too small; nothing was written. */
    DATEPARSA_BUFFER_TOO_SMALL = 5
} dateparsa_status;

/* What sort of time a result is. */
typedef enum dateparsa_kind {
    /* A structured date or a timestamp: "2024-03-15", "March 15, 2024". */
    DATEPARSA_KIND_ABSOLUTE = 0,
    /* Relative to the base time: "3 days ago", "yesterday". */
    DATEPARSA_KIND_RELATIVE = 1,
    /* The base time itself, or its day: "now", "today". */
    DATEPARSA_KIND_NOW = 2
} dateparsa_kind;

/*
 * Locales whose month names and relative words are read besides English,
 * which always is. One bit per locale, in tag order, the same in every
 * build; dateparsa_locales_compiled says which this build has.
 */
#define DATEPARSA_LOCALE_AR 0x00001u
#define DATEPARSA_LOCALE_DA 0x00002u
#define DATEPARSA_LOCALE_DE 0x00004u
#define DATEPARSA_LOCALE_EN 0x00008u
#define DATEPARSA_LOCALE_ES 0x00010u
#define DATEPARSA_LOCALE_FI 0x00020u
#define DATEPARSA_LOCALE_FR 0x00040u
#define DATEPARSA_LOCALE_HI 0x00080u
#define DATEPARSA_LOCALE_IT 0x00100u
#define DATEPARSA_LOCALE_JA 0x00200u
#define DATEPARSA_LOCALE_KO 0x00400u
#define DATEPARSA_LOCALE_NL 0x00800u
#define DATEPARSA_LOCALE_NO 0x01000u
#define DATEPARSA_LOCALE_PL 0x02000u
#define DATEPARSA_LOCALE_PT 0x04000u
#define DATEPARSA_LOCALE_RU 0x08000u
#define DATEPARSA_LOCALE_SV 0x10000u
#define DATEPARSA_LOCALE_TR 0x20000u
#define DATEPARSA_LOCALE_UK 0x40000u
#define DATEPARSA_LOCALE_ZH 0x80000u

/* The longest dateparsa_format_rfc3339 writes, its NUL included. */
#define DATEPARSA_RFC3339_MAX 48

/*
 * A civil date and time with a fixed UTC offset. One passed in must be a
 * real date and time: month 1 to 12, a day that month has, hour 0 to 23,
 * minute and second 0 to 59, nanosecond under 1000000000, and an offset
 * within a day either way.
 */
typedef struct dateparsa_datetime {
    int32_t year; /* astronomical: year 0 is 1 BC */
    uint8_t month;
    uint8_t day;
    uint8_t hour;
    uint8_t minute;
    uint8_t second;
    uint32_t nanosecond;
    int32_t offset_seconds; /* east of UTC */
} dateparsa_datetime;

/* One way to read an input strict mode refused to choose for. */
typedef struct dateparsa_interpretation {
    dateparsa_datetime time;
    /* "MM/DD/YYYY", "DD/MM/YY", "MONTH_YEAR", "NATURAL_LANGUAGE". */
    const char *label;
    size_t label_len;
} dateparsa_interpretation;

/* What a failed call can say beyond its status, when the options ask. */
typedef struct dateparsa_diagnostics {
    /* On DATEPARSA_AMBIGUOUS: the readings that fit, the preferred one
     * first. */
    dateparsa_interpretation interpretations[3];
    uint8_t interpretation_count;
    /* What refused the input or the argument. */
    const char *message;
    size_t message_len;
} dateparsa_diagnostics;

/* How to read an input. Zeroed is the default. */
typedef struct dateparsa_options {
    /* What relative expressions and year-less formats are read against.
     * NULL means such inputs fail with DATEPARSA_NO_BASE_TIME. Its year must
     * be within 999999999 either way of year 0. */
    const dateparsa_datetime *base_time;
    /* UTC offset, seconds east, for an input that writes no zone. Within a
     * day either way. */
    int32_t timezone_offset;
    /* DATEPARSA_LOCALE_* bits. A locale this build did not compile in is
     * DATEPARSA_INVALID_ARGUMENT. */
    uint32_t locales;
    /* "01/02/2024" is the 1st of February. */
    bool prefer_day_first;
    /* "01/02/03" is 2001-02-03. */
    bool prefer_year_first;
    /* A bare weekday is the next one, not the last. */
    bool prefer_future;
    /* Refuse a guess with DATEPARSA_AMBIGUOUS instead of taking it. */
    bool strict;
    /* Filled in when a call fails, if not NULL. */
    dateparsa_diagnostics *diagnostics;
} dateparsa_options;

/*
 * A detected format, compiled, to re-parse the rest of a column with.
 * Opaque: copy it freely within one process, but only a layout the library
 * filled in is a layout.
 */
#define DATEPARSA_LAYOUT_SIZE 256
typedef union dateparsa_layout {
    unsigned char bytes[DATEPARSA_LAYOUT_SIZE];
    uint64_t align_u64_;
    void *align_ptr_;
} dateparsa_layout;

/* A successful parse. */
typedef struct dateparsa_result {
    dateparsa_datetime time;
    /* time as seconds since 1970-01-01T00:00:00Z; time.nanosecond is the
     * rest. */
    int64_t unix_seconds;
    /* A dateparsa_kind. */
    uint8_t kind;
    /* The input needed a guess: "01/02/2024" is the 2nd of January or the
     * 1st of February, and the preferences picked one. */
    bool ambiguous;
    /* layout may parse the rest of a column: false for timestamps, natural
     * language, and formats whose month and day are decided per value. */
    bool reusable;
    /* The format's name: "ISO8601_DATE", "NUMERIC_MDY". */
    const char *label;
    size_t label_len;
    dateparsa_layout layout;
} dateparsa_result;

/* Parses a column, reusing the first value's layout where it can. */
#define DATEPARSA_PARSER_SIZE 384
typedef union dateparsa_parser {
    unsigned char bytes[DATEPARSA_PARSER_SIZE];
    uint64_t align_u64_;
    void *align_ptr_;
} dateparsa_parser;

/* The order a numeric date writes its year, month and day in. */
typedef enum dateparsa_order {
    /* Nothing settled it, or the values contradict each other evenly. */
    DATEPARSA_ORDER_NONE = -1,
    /* "03/04/2024" is the 4th of March. */
    DATEPARSA_ORDER_MONTH_FIRST = 0,
    /* "03/04/2024" is the 3rd of April. */
    DATEPARSA_ORDER_DAY_FIRST = 1,
    /* "24/03/04" is the 4th of March 2024. */
    DATEPARSA_ORDER_YEAR_FIRST = 2
} dateparsa_order;

/*
 * Settles which order a column writes its numeric dates in, from all of its
 * values where one cannot: one "13/02/2024" anywhere means day first for all
 * of it. Opaque, like dateparsa_parser, and used by one thread at a time.
 */
#define DATEPARSA_COLUMN_SIZE 256
typedef union dateparsa_column {
    unsigned char bytes[DATEPARSA_COLUMN_SIZE];
    uint64_t align_u64_;
    void *align_ptr_;
} dateparsa_column;

/* What a column's values say about its order. */
typedef struct dateparsa_column_report {
    /* A dateparsa_order: the one order every value with a say fits, or, when
     * none fits them all, the one the fewest contradict. */
    int32_t order;
    /* Bit (1 << order) for each order every value with a say fits; 0 when
     * they contradict each other. */
    uint32_t fits;
    /* Set these in your options to read the column in order; both false
     * when order is DATEPARSA_ORDER_NONE. */
    bool prefer_day_first;
    bool prefer_year_first;
    /* Values added; values with a say (a format whose field order is
     * decided per value); values that did not parse; values with a say that
     * order does not fit. */
    uint64_t values;
    uint64_t voted;
    uint64_t failed;
    uint64_t conflicts;
    /* The index of the value after which order was the only one left, and
     * of the first value order does not fit; -1 for none. */
    int64_t settled_by;
    int64_t first_conflict;
} dateparsa_column_report;

/* The library's version, as in its build.zig.zon ("0.1.0"): static,
 * NUL-terminated. */
const char *dateparsa_version(void);

/* The DATEPARSA_LOCALE_* bits this build compiled in. */
uint32_t dateparsa_locales_compiled(void);

/* The bit of the locale a BCP 47 tag names ("fr", "fr-CA"), into *bit.
 * DATEPARSA_NO_MATCH when this build did not compile it in. */
dateparsa_status dateparsa_locale_lookup(const char *tag, size_t len, uint32_t *bit);

/* input parsed as a structured date, then as a Unix timestamp, then as a
 * natural-language expression, into *out. Surrounding ASCII whitespace is
 * padding. options may be NULL for the default. */
dateparsa_status dateparsa_parse(const char *input, size_t len,
                                 const dateparsa_options *options,
                                 dateparsa_result *out);

/* The layout input is written in, into *out. */
dateparsa_status dateparsa_detect(const char *input, size_t len,
                                  const dateparsa_options *options,
                                  dateparsa_layout *out);

/* input read with layout's format, into *out: no detection. A layout from a
 * timestamp or natural language refuses everything. */
dateparsa_status dateparsa_layout_parse(const dateparsa_layout *layout,
                                        const char *input, size_t len,
                                        dateparsa_datetime *out);

/* Whether layout may parse the rest of a column. */
bool dateparsa_layout_reusable(const dateparsa_layout *layout);

/* layout's format name, its length into *len. */
const char *dateparsa_layout_label(const dateparsa_layout *layout, size_t *len);

/* A parser reading every value with options, whose diagnostics pointer it
 * keeps for every later call. */
dateparsa_status dateparsa_parser_init(dateparsa_parser *parser,
                                       const dateparsa_options *options);

/* input parsed with the cached layout when it can read it, and detected
 * afresh otherwise, which also replaces the cache. Always the answer
 * dateparsa_parse would give. */
dateparsa_status dateparsa_parser_parse(dateparsa_parser *parser,
                                        const char *input, size_t len,
                                        dateparsa_result *out);

/* Forgets the cached layout. */
void dateparsa_parser_reset(dateparsa_parser *parser);

/* A column with no values yet, read with options (strict mode and the
 * diagnostics pointer set aside). */
dateparsa_status dateparsa_column_init(dateparsa_column *column,
                                       const dateparsa_options *options);

/* Notes what input says about the column's order. */
dateparsa_status dateparsa_column_add(dateparsa_column *column,
                                      const char *input, size_t len);

/* What the values added so far say, into *out. */
dateparsa_status dateparsa_column_summarize(const dateparsa_column *column,
                                            dateparsa_column_report *out);

/* time written as RFC 3339 ("2024-03-15T10:30:00.123Z") into buf, with a
 * terminating NUL, its length without the NUL into *len. A year outside
 * 0000 to 9999 takes the digits it needs, and the offset's seconds are
 * dropped. len may be NULL. DATEPARSA_BUFFER_TOO_SMALL unless cap fits it;
 * DATEPARSA_RFC3339_MAX always does. */
dateparsa_status dateparsa_format_rfc3339(const dateparsa_datetime *time,
                                          char *buf, size_t cap, size_t *len);

/* time as seconds since 1970-01-01T00:00:00Z, into *seconds. */
dateparsa_status dateparsa_to_unix(const dateparsa_datetime *time, int64_t *seconds);

#ifdef __cplusplus
}
#endif

#endif /* DATEPARSA_H */
