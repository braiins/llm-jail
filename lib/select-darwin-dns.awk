# Select the first usable IPv4 resolver from scutil's ordinary DNS section.
# Resolver metadata follows nameserver lines, so decide at block boundaries.

function ipv4_address_p(address, octets, octet_count, octet_index) {
  octet_count = split(address, octets, ".")
  if (octet_count != 4) {
    return 0
  }

  for (octet_index = 1; octet_index <= octet_count; octet_index++) {
    if (octets[octet_index] !~ /^[0-9]+$/ || octets[octet_index] + 0 > 255) {
      return 0
    }
  }

  return 1
}

function finish_resolver() {
  if (ordinary_section && in_resolver && !excluded && candidate != "") {
    print candidate
    selected = 1
  }
}

$0 == "DNS configuration" {
  finish_resolver()
  if (selected) {
    exit
  }

  ordinary_section = 1
  in_resolver = 0
  next
}

$0 ~ /^DNS configuration/ {
  finish_resolver()
  if (selected) {
    exit
  }

  ordinary_section = 0
  in_resolver = 0
  next
}

$0 ~ /^resolver #[0-9]+$/ {
  if (ordinary_section) {
    finish_resolver()
    if (selected) {
      exit
    }

    in_resolver = 1
    excluded = 0
    candidate = ""
  } else {
    in_resolver = 0
  }
  next
}

ordinary_section && in_resolver {
  if ($0 ~ /(Supplemental|Scoped)/) {
    excluded = 1
  }

  if (candidate == "" &&
      $1 ~ /^nameserver\[[0-9]+\]$/ &&
      $2 == ":" &&
      ipv4_address_p($3)) {
    candidate = $3
  }
}

END {
  if (!selected) {
    finish_resolver()
  }
}
