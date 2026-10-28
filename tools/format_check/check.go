// Parses each go row of `zig build format-strings` with time.Parse and
// compares the fields the layout sets with what dateparsa read. Exits 1 on
// any difference.
package main

import (
	"bufio"
	"fmt"
	"os"
	"runtime"
	"strings"
	"time"
)

func main() {
	sc := bufio.NewScanner(os.Stdin)
	checked, failed := 0, 0
	for sc.Scan() {
		p := strings.Split(sc.Text(), "\t")
		if p[0] != "go" || p[2] == "-" {
			continue
		}
		checked++
		var w [8]int
		fmt.Sscan(p[4], &w[0], &w[1], &w[2], &w[3], &w[4], &w[5], &w[6], &w[7])
		t, err := time.Parse(p[2], p[1])
		if err != nil {
			fmt.Printf("go: %q with %q: %v\n", p[1], p[2], err)
			failed++
			continue
		}
		_, off := t.Zone()
		got := map[rune]int{'Y': t.Year(), 'M': int(t.Month()), 'D': t.Day(), 'h': t.Hour(), 'm': t.Minute(), 's': t.Second(), 'f': t.Nanosecond(), 'z': off}
		exp := map[rune]int{'Y': w[0], 'M': w[1], 'D': w[2], 'h': w[3], 'm': w[4], 's': w[5], 'f': w[6], 'z': w[7]}
		var diff []string
		for _, c := range p[3] {
			if g, ok := got[c]; ok && g != exp[c] {
				diff = append(diff, fmt.Sprintf("%c %d != %d", c, g, exp[c]))
			}
		}
		if len(diff) > 0 {
			fmt.Printf("go: %q with %q: %s\n", p[1], p[2], strings.Join(diff, ", "))
			failed++
		}
	}
	fmt.Printf("go (%s): %d checked, %d failed\n", runtime.Version(), checked, failed)
	if failed > 0 || checked == 0 {
		os.Exit(1)
	}
}
