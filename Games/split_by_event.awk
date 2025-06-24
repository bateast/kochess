#!/usr/bin/awk -f
# ----------------------------------------
# split_by_event.awk
# Usage: awk -f split_by_event.awk games.pgn
# Splits into files named after the Event tag.
# ----------------------------------------

# Function to sanitize a string into a safe filename
function sanitize(s,    t) {
    t = s
    # replace spaces with underscores
    gsub(/[[:space:]]+/, "_", t)
    # remove or replace unsafe filesystem chars
    gsub(/[^A-Za-z0-9._-]/, "", t)
    return t
}

BEGIN {
    out = ""     # current output filename
}

/^\[Event[[:space:]]+/ {
    # Extract between the first and last double-quote
    if (match($0, /"([^"]+)"/, m)) {
        ev = m[1]
    } else {
        ev = "UnknownEvent"
    }
    ev = sanitize(ev)
    # Optionally add a numeric prefix to avoid collisions:
    count++
    filename = sprintf("%03d_%s.pgn", count, ev)
    # close previous, set new 'out'
    if (out) close(out)
    out = filename
}

{
    # Print every line into the current output file
    # Once the first Event has been seen, out is non-empty
    if (out) print >> out
}
