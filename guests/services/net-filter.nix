{ pkgs, ... }:

{
  # Configures DNS whitelist (dnsmasq) and port-level firewall (nftables)
  # when llmjail.net_filter=1 is set on the kernel cmdline.
  systemd.services.llmjail-net-filter = {
    description = "llmjail network filter (DNS whitelist + nftables)";
    wantedBy = [ "multi-user.target" ];
    after = [ "llmjail-mounts.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    before = [ "llmjail-tool.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail

      NET_FILTER=0
      for arg in $(cat /proc/cmdline); do
        case "$arg" in
          llmjail.net_filter=1) NET_FILTER=1 ;;
        esac
      done

      if [ "$NET_FILTER" != "1" ]; then
        echo "Network filtering disabled."
        exit 0
      fi

      # Must run before dnsmasq so allowed_ips set exists when
      # dnsmasq populates it on first DNS resolution.
      ${pkgs.nftables}/bin/nft -f - <<'NFTEOF'
      table inet llmjail_filter {
        # Populated by dnsmasq --nftset on each successful DNS resolution.
        # HTTP/HTTPS is only allowed to IPs that appear here, blocking
        # direct hardcoded-IP connections that bypass DNS filtering.
        # Plain set (no `flags interval`) so dnsmasq can add individual
        # /32 entries - interval sets reject single addresses in some
        # nft/dnsmasq combos.
        set allowed_ips {
          type ipv4_addr
        }

        chain output {
          type filter hook output priority 0; policy drop;

          oifname "lo" accept

          ct state established,related accept

          udp dport { 67, 68 } accept

          ip daddr 10.0.2.3 udp dport 53 meta skuid root accept
          ip daddr 10.0.2.3 tcp dport 53 meta skuid root accept

          ip daddr @allowed_ips tcp dport { 80, 443 } accept

          log prefix "llmjail-drop: " drop
        }
      }
      NFTEOF

      DNSMASQ_CONF="/etc/dnsmasq-llmjail.conf"
      {
        echo "no-resolv"
        echo "no-hosts"
        echo "listen-address=127.0.0.1"
        echo "bind-interfaces"

        # Forward allowed domains to QEMU's DNS; populate nftables set
        # on each successful resolution so the IP becomes reachable.
        if [ -f /llmjail-env/allowed-domains ]; then
          while IFS= read -r domain || [ -n "$domain" ]; do
            [ -z "$domain" ] && continue
            echo "server=/$domain/10.0.2.3"
            echo "nftset=/$domain/4#inet#llmjail_filter#allowed_ips"
          done < /llmjail-env/allowed-domains
        fi

        # No default upstream - unmatched queries get REFUSED
      } > "$DNSMASQ_CONF"

      # --user=root keeps CAP_NET_ADMIN for the lifetime of the daemon;
      # dnsmasq otherwise drops to "nobody" and nftset updates fail
      # silently. We're inside a jail VM, root for dnsmasq is fine.
      # --log-queries surfaces the nftset add events in journalctl so
      # future filter regressions are debuggable from the guest.
      ${pkgs.dnsmasq}/bin/dnsmasq \
        --conf-file="$DNSMASQ_CONF" \
        --pid-file=/run/dnsmasq-llmjail.pid \
        --user=root \
        --log-queries=extra \
        --log-facility=-

      echo "nameserver 127.0.0.1" > /etc/resolv.conf

      echo "Network filtering enabled with $(${pkgs.coreutils}/bin/wc -l < /llmjail-env/allowed-domains) allowed domain(s)."
    '';
  };
}
