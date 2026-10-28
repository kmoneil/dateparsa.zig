// Parses each java row of `zig build format-strings` with
// DateTimeFormatter (English names, the default SMART resolver) and
// compares the fields the pattern sets with what dateparsa read. Exits 1 on
// any difference.
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.time.LocalDateTime;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.time.temporal.ChronoField;
import java.time.temporal.TemporalAccessor;
import java.time.temporal.TemporalQueries;
import java.util.ArrayList;
import java.util.Locale;

public class Check {
    public static void main(String[] args) throws Exception {
        var in = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
        int checked = 0, failed = 0;
        String line;
        while ((line = in.readLine()) != null) {
            String[] p = line.split("\t", -1);
            if (!p[0].equals("java") || p[2].equals("-")) continue;
            checked++;
            String[] w = p[4].split(" ");
            TemporalAccessor t;
            try {
                t = DateTimeFormatter.ofPattern(p[2], Locale.ENGLISH).parse(p[1]);
            } catch (Exception e) {
                System.out.printf("java: \"%s\" with \"%s\": %s%n", p[1], p[2], e.getMessage());
                failed++;
                continue;
            }
            var diff = new ArrayList<String>();
            for (char c : p[3].toCharArray()) {
                long got;
                long want;
                switch (c) {
                    case 'Y' -> { got = t.getLong(ChronoField.YEAR); want = Long.parseLong(w[0]); }
                    case 'M' -> { got = t.getLong(ChronoField.MONTH_OF_YEAR); want = Long.parseLong(w[1]); }
                    case 'D' -> { got = t.getLong(ChronoField.DAY_OF_MONTH); want = Long.parseLong(w[2]); }
                    case 'h' -> { got = t.getLong(ChronoField.HOUR_OF_DAY); want = Long.parseLong(w[3]); }
                    case 'm' -> { got = t.getLong(ChronoField.MINUTE_OF_HOUR); want = Long.parseLong(w[4]); }
                    case 's' -> { got = t.getLong(ChronoField.SECOND_OF_MINUTE); want = Long.parseLong(w[5]); }
                    case 'f' -> { got = t.getLong(ChronoField.NANO_OF_SECOND); want = Long.parseLong(w[6]); }
                    case 'z' -> { got = offset(t); want = Long.parseLong(w[7]); }
                    default -> { continue; }
                }
                if (got != want) diff.add(c + " " + got + " != " + want);
            }
            if (!diff.isEmpty()) {
                System.out.printf("java: \"%s\" with \"%s\": %s%n", p[1], p[2], String.join(", ", diff));
                failed++;
            }
        }
        System.out.printf("java (%s): %d checked, %d failed%n", System.getProperty("java.version"), checked, failed);
        System.exit(failed > 0 || checked == 0 ? 1 : 0);
    }

    // An offset the pattern read, or the offset of a zone it named, then.
    static long offset(TemporalAccessor t) {
        if (t.isSupported(ChronoField.OFFSET_SECONDS)) return t.getLong(ChronoField.OFFSET_SECONDS);
        ZoneId z = t.query(TemporalQueries.zone());
        if (z == null) return Long.MIN_VALUE; // the pattern read no zone: a difference
        return z.getRules().getOffset(LocalDateTime.from(t)).getTotalSeconds();
    }
}
