# Tailscale Subnet Router: CGNAT Remote Access

**Status:** Deployed 2026-07-22 · **Host:** pve3 · **CTID:** 200 · **Node:** `tailscale-subnet-router` (`100.120.40.104`, tailnet `tailb36c18.ts.net`)

A single Debian 12 LXC on Proxmox runs Tailscale as a subnet router, advertising the VLAN 10
infrastructure subnet (`10.0.10.0/24`) into the tailnet so management workstations can reach the
cluster and Proxmox hosts from any network, including CGNAT LTE where inbound WireGuard cannot
work. The router is single-homed on VLAN 10; the management plane (VLAN 99) is intentionally not
remotely reachable (see below).

---

## Why this exists

The WAN is CGNAT (carrier-grade NAT: `100.71.3.65/18`, gw `100.71.0.1`). There is no
public, port-forwardable inbound path, so the existing OPNsense WireGuard road-warrior
(`wg_roadwarrior`, UDP 63812, tunnel `10.6.0.0/24`) only works when the client is already on a
network that can reach the OPNsense WAN, not from an LTE hotspot behind CGNAT.

Tailscale works here because both ends dial out to Tailscale's coordination/DERP relays;
no inbound port is required. When direct NAT traversal fails (as it does under double CGNAT),
traffic relays through DERP, measured here at ~40-90 ms via DERP(mia), which is adequate for
management traffic (SSH, web UIs, `kubectl`).

This is additive and isolated by design:

- OPNsense WireGuard stays in place, untouched, as the on-LAN-reachable path. `10.6.0.0/24` is
  WireGuard transport space and is intentionally not advertised into the tailnet.
- Tailscale runs in a dedicated LXC only, never on a K3s node or on OPNsense, so the CNI,
  kube-vip, MetalLB, Longhorn, and firewall routing are all left alone.

---

## Design decisions

| Decision | Choice | Rationale |
|---|---|---|
| Where | Isolated Debian 12 LXC on Proxmox | Keeps Tailscale off the cluster/firewall |
| Which host | pve3 | pve3 had the most headroom (15 GB free RAM, load 0.25). pve2 was excluded at build time (surge-only UPS side, cause of the May 20 unclean shutdown; outlet remediated 2026-07-22), but pve3 remains the chosen host on headroom grounds. The router is the SPOF for the CGNAT path. |
| Auth identity | Tagged node (`tag:subnet-router`) | A tag makes the node ACL-governed and non-expiring (tagged devices auto-disable key expiry), so the remote path does not drop on key expiry. A user-owned login would expire. |
| Reach scope | Single NIC on VLAN 10, routes `10.0.10.0/24` only | Directly connected; covers the whole cluster, all Proxmox hosts, and the kube-vip VIP. The management plane (VLAN 99) is intentionally not remotely reachable: it stays LAN-local by design, and remote firewall/switch/JetKVM admin is not a requirement. Keeping the router single-homed also keeps it out of the MGMT segment entirely. |

---

## LXC specification

| Field | Value |
|---|---|
| Host / CTID | pve3 (`10.0.10.12`) / 200 |
| Hostname | `tailscale-subnet-router` |
| Template | `debian-12-standard_12.12-1_amd64` |
| Type | Unprivileged, `features: nesting=1`, `onboot: 1` |
| Resources | 1 vCPU / 512 MB RAM / 512 MB swap / 8 GB rootfs on `local-zfs` |
| `net0` (VLAN 10) | `eth0`, `bridge=vmbr0,tag=10`, `ip=10.0.10.5/24`, `gw=10.0.10.1`, MTU 1500 |
| DNS | `nameserver 10.0.10.1` (OPNsense Unbound), `searchdomain homelab.local` |

Single-homed on VLAN 10. Default route via `eth0`/`10.0.10.1`. `10.0.10.5` was confirmed free
before use (live ping sweep of `10.0.10.0/24`).

`eth0` is pinned to MTU 1500 (explicit `mtu=1500`, overriding the jumbo 9000 inherited from
`vmbr0`). This is a low-throughput management appliance; 1500 avoids jumbo-frame/PMTUD edge cases.

### `/dev/net/tun` passthrough

Appended to `/etc/pve/lxc/200.conf` (required for `tailscaled` in an unprivileged container):

```
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
```

### Persistent IP forwarding

`/etc/sysctl.d/99-tailscale.conf` inside the container (applied with `sysctl --system`;
re-applied at boot by `systemd-sysctl`, so it survives reboot):

```
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
```

> Note: `sysctl --system` returns non-zero in an unprivileged LXC because it also tries to set
> non-namespaced host sysctls it cannot touch. The two namespaced net values apply cleanly
> (`sysctl -p /etc/sysctl.d/99-tailscale.conf` → rc 0, both read back as `1`).

---

## Tailscale

Installed via the official script (`curl -fsSL https://tailscale.com/install.sh | sh`),
version 1.98.9. `tailscaled` is enabled (autostarts and reconnects on boot; state in
`/var/lib/tailscale`). Joined with a single-use tagged auth key (consumed immediately; never
written to any file or committed):

```
tailscale up \
  --advertise-routes=10.0.10.0/24 \
  --accept-dns=false \
  --advertise-tags=tag:subnet-router \
  --authkey=<single-use tagged key, runtime only, never stored>
```

`--accept-dns=false` is deliberate: MagicDNS must not shadow the OPNsense Unbound
split-horizon resolver (`.homelab.local` overrides). Confirmed `CorpDNS: false` on the node.

Client side, the management Mac joined with `--accept-routes --accept-dns=false`
(`RouteAll: true`), owned by `RedSkelly@github`.

---

## ACL policy (operator-maintained)

The cluster runs zero NetworkPolicies, so this ACL is the only thing restricting
tailnet-side access into the infra subnet. It replaces the default allow-all and restricts
the single advertised route to the operator's identity. The live policy is maintained by the
operator in the admin console; the documented target is:

```jsonc
{
  // Only the operator's identity may own/assign this tag.
  "tagOwners": {
    "tag:subnet-router": ["RedSkelly@github"]
  },

  // Auto-approve the advertised route when advertised by a tagged router,
  // so future reprovisioning needs no manual route approval.
  "autoApprovers": {
    "routes": {
      "10.0.10.0/24": ["tag:subnet-router"]
    }
  },

  // Replaces the default allow-all. Only RedSkelly@github gets access.
  "acls": [
    { "action": "accept", "src": ["RedSkelly@github"], "dst": ["RedSkelly@github:*"] },
    { "action": "accept", "src": ["RedSkelly@github"], "dst": ["tag:subnet-router:*"] },
    { "action": "accept", "src": ["RedSkelly@github"], "dst": ["10.0.10.0/24:*"] }
  ]
}
```

> Sequencing: apply the ACL before minting the tagged auth key. Tailscale will not issue a key
> for a tag that is not defined in `tagOwners`, and `autoApprovers` only auto-approves once the
> policy is live. Order: apply ACL → generate key → `tailscale up`.

Key expiry: the node does not expire because it is tagged (Tailscale disables key expiry on
tagged devices automatically). No manual per-node setting is required; confirmed in the
Machines tab.

---

## Verification results

| Check | Result |
|---|---|
| IP forwarding (v4 + v6) inside LXC | Pass: both `= 1`; drop-in applies with rc 0 |
| `/dev/net/tun` present | Pass: `crw-rw-rw- 10, 200` |
| VLAN 10 gateway + internet from LXC | Pass: 0% loss to `10.0.10.1` and `1.1.1.1` |
| Single default route | Pass: only via `eth0`/`10.0.10.1` |
| Node online + tagged + advertising `10.0.10.0/24` | Pass: `BackendState: Running`, `tag:subnet-router`, `[10.0.10.0/24]` |
| Route approved (autoApprovers) | Pass: `tailscale ping` to VLAN 10 IPs resolves via the router (unapproved routes would fail) |
| Client joined, accepting routes | Pass: `RedSkelly@github`, `RouteAll: true` |
| Overlay reach → `{10.0.10.49, 10.0.10.10}` | Pass: `tailscale ping` pong via router, ~40-90 ms DERP(mia) |
| VLAN 99 not reachable | Pass: `tailscale ping 10.0.99.100` → `no matching peer` (route withdrawn) |
| Off-LAN acceptance test (LTE) | Pass 2026-07-22 from LTE: `ping 10.0.10.49`, `ping 10.0.10.10`, `kubectl --context homelab get nodes` (6 Ready) |

---

## Security notes

- The management plane (VLAN 99) is not remotely reachable. The router is single-homed on
  VLAN 10; remote firewall/switch/JetKVM administration is not a requirement, so the MGMT
  segment stays LAN-local and the OPNsense VLAN 10 → VLAN 99 segmentation is left intact. The
  router is never placed on the MGMT segment.
- The Tailscale ACL is the only compensating control for the cluster's zero NetworkPolicies.
  It restricts the advertised route to `RedSkelly@github` and replaces the default allow-all.
  Do not revert it to allow-all.
- The subnet router is a single ingress point into VLAN 10.
- The node is tagged and non-expiring by design, so the CGNAT path does not drop silently.

---

## Operational notes and follow-ups

- History: originally provisioned dual-homed with a second NIC on VLAN 99 (JetKVM/MGMT
  reach). Collapsed to VLAN 10 only on 2026-07-22, since the management plane stays LAN-local by
  design. `net1` removed; the router is single-homed.
- Host placement: on pve3. pve2 was excluded during build (surge-only UPS outlet, remediated
  2026-07-22) but pve3 remains chosen on headroom grounds. Record the host if this is ever
  rebuilt.
- Boot persistence is complete: `onboot=1` (container autostarts), `tailscaled` enabled
  (reconnects, state persisted), forwarding via `sysctl.d`, the IP in the LXC config. A full
  reboot-persistence test is still outstanding.
- Stale tailnet nodes: ~~remove offline `redskelly` duplicates~~ removed 2026-07-22.
- UDP GRO hint: `tailscale up` warned that UDP GRO forwarding on `eth0` is suboptimal
  (see `tailscale.com/s/ethtool-config-udp-gro`). Throughput optimization only, not correctness;
  low priority for management traffic and constrained by the unprivileged LXC. Left as-is.
- Pre-existing, unrelated: `/etc/pve/datacenter.cfg` has a schema parse warning
  (`'nameserver': property is not defined`) surfaced on every `pct`/`pveam` call. Not introduced
  by this work; fix separately.
- IaC ownership: this LXC was provisioned by hand. Its lifecycle belongs in Terraform
  (bpg/proxmox, roadmap item 7) alongside the VM definitions, since the hypervisor is
  authoritative for the container spec, NIC/VLAN tag, and `/dev/net/tun` passthrough.

---

## Reproduce from scratch (on the chosen pve host, as root)

```bash
# 1. Template
pveam update && pveam download local debian-12-standard_12.12-1_amd64.tar.zst

# 2. Create the unprivileged, single-homed LXC (VLAN 10 only)
pct create 200 local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst \
  --hostname tailscale-subnet-router --unprivileged 1 \
  --cores 1 --memory 512 --swap 512 --rootfs local-zfs:8 \
  --net0 name=eth0,bridge=vmbr0,tag=10,ip=10.0.10.5/24,gw=10.0.10.1,mtu=1500 \
  --nameserver 10.0.10.1 --searchdomain homelab.local \
  --ostype debian --features nesting=1 --onboot 1

# 3. /dev/net/tun passthrough, then start
cat >> /etc/pve/lxc/200.conf <<'EOF'
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
EOF
pct start 200

# 4. Persistent forwarding
pct exec 200 -- bash -c 'printf "net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\n" \
  > /etc/sysctl.d/99-tailscale.conf && sysctl -p /etc/sysctl.d/99-tailscale.conf'

# 5. Install + join (ACL must already define tag:subnet-router; key is single-use, tagged)
pct exec 200 -- bash -c 'curl -fsSL https://tailscale.com/install.sh | sh'
pct exec 200 -- tailscale up \
  --advertise-routes=10.0.10.0/24 \
  --accept-dns=false --advertise-tags=tag:subnet-router \
  --authkey=<single-use tagged key>
```
