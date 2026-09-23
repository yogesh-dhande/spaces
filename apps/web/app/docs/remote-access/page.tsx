import type { Metadata } from "next";
import Link from "next/link";
import { CodeBlock, InlineCode } from "../components/code-block";
import { DocsShell } from "../components/docs-shell";
import { Prose, Section } from "../components/section";

const tailscaleInstallURL = "https://tailscale.com/kb/1017/install";
const tailscaleFirewallURL = "https://tailscale.com/kb/1082/firewall-ports";
const tailscaleKeyExpiryURL = "https://tailscale.com/kb/1028/key-expiry";

const listClass = "mt-3 space-y-2 text-sm leading-7 text-foreground-soft";
const subheadingClass = "mt-6 text-sm font-semibold text-foreground";
const paragraphClass = "mt-3 text-sm leading-7 text-foreground-soft";

export const metadata: Metadata = {
  title: "Remote Access",
  description:
    "Reach a remote machine or cloud VM from your Mac and iPhone wherever you are: pair over Tailscale, keep the daemon running, and verify the connection survives a change of network.",
};

export default function RemoteAccessDocsPage() {
  return (
    <DocsShell
      title="Remote Access"
      description="Set up a Linux box or cloud VM so your Mac and iPhone reach it from home Wi-Fi, a coffee shop, and cellular alike. The setup here uses Tailscale for the network path and leaves nothing on the machine open to the public internet."
      pagePath="/docs/remote-access"
    >
      <Section title="Two connections, not one">
        <Prose>
          A remote machine is reached over two different connections, and a working first one says nothing about the second.
        </Prose>
        <ul className={listClass}>
          <li>• <strong>SSH, from the Mac.</strong> Pairing from a Mac, installing the daemon, and updating it over SSH ride your SSH access, usually TCP <InlineCode>22</InlineCode>. Two Mac features keep using it after pairing: a browser session for a remote workspace&apos;s service opens through an SSH local forward, and opening a remote workspace in an external editor goes through that editor&apos;s SSH remote support. Your phone never uses SSH: pairing a phone hands over a credential through a QR code or a link, and everything the phone does afterwards goes over the second connection.</li>
          <li>• <strong>Port 47847, for Spaces itself.</strong> Once paired, your Mac and your phone each talk to the machine&apos;s Spaces daemon directly on TCP <InlineCode>47847</InlineCode>. Terminals, coding agents, the built-in Editor, and the phone&apos;s browser sessions all go over this connection. It is authenticated end to end: a client pins the daemon&apos;s certificate and presents a per-client token, so nothing on the machine trusts an address by itself.</li>
        </ul>
        <p className={paragraphClass}>
          When SSH works and Spaces reports the device as unreachable, it is the second connection that is failing. A cloud console, an IAP tunnel, or a jump host proves the machine is up; it does not carry Spaces traffic.
        </p>
        <p className={paragraphClass}>
          A paired device is not stored as one address. The pairing link carries a short list of candidate addresses, most preferred first: the host you paired over SSH, the machine&apos;s primary local-network address, and its Tailscale address when it has one. A secondary interface on the machine is not in that list. Each client tries them in that order, keeps whichever answers, remembers it for next time, and learns the daemon&apos;s current addresses again on every connection. That is what lets one pairing follow you between networks.
        </p>
      </Section>

      <Section title="Recommended setup: Tailscale on every device">
        <Prose>
          Put the remote machine, your Mac, and your iPhone on one tailnet and pair using the machine&apos;s Tailscale address. The address stays the same on every network you move to, nothing has to be opened to the public internet, and the Spaces daemon needs no configuration to be reached this way: it listens on every interface, including the Tailscale one.
        </Prose>

        <h3 className={subheadingClass}>1. Install Tailscale</h3>
        <p className={paragraphClass}>
          Follow the{" "}
          <Link href={tailscaleInstallURL} className="text-accent hover:underline" target="_blank" rel="noopener noreferrer">
            official installation instructions
          </Link>{" "}
          on the remote machine, on your Mac, and on your iPhone, and sign each one into the same tailnet. On the machine, confirm it is up and note its address:
        </p>
        <CodeBlock>{`tailscale status
tailscale ip -4`}</CodeBlock>
        <p className={paragraphClass}>
          Tailscale itself has to keep running on the machine after you disconnect, so check that its service is enabled to start at boot: <InlineCode>systemctl is-enabled tailscaled</InlineCode>. Node keys expire by default; for a server you plan to leave running, disable key expiry for that machine in the Tailscale admin console (see{" "}
          <Link href={tailscaleKeyExpiryURL} className="text-accent hover:underline" target="_blank" rel="noopener noreferrer">
            key expiry
          </Link>
          ), or the machine drops off the tailnet months later with nothing else having changed.
        </p>

        <h3 className={subheadingClass}>2. Install Spaces on the machine</h3>
        <p className={paragraphClass}>
          Pairing from a Mac installs the daemon for you if it is missing, or run the installer yourself first. Both are covered under <strong>Linux</strong> on the{" "}
          <Link href="/docs/installation" className="text-accent hover:underline">
            Installation
          </Link>{" "}
          page. Either way the machine ends up with <InlineCode>spacesd.service</InlineCode> running as a systemd user service with lingering enabled, which is what keeps your sessions alive after you disconnect.
        </p>

        <h3 className={subheadingClass}>3. Pair your Mac over the Tailscale address</h3>
        <p className={paragraphClass}>
          Connect over SSH once by hand so the machine&apos;s host key is recorded, verifying the key through the cloud console or another trusted channel before accepting it. Then pair using the Tailscale address (or the machine&apos;s MagicDNS name) as the host, either from <strong>Settings → Devices → Add remote device over SSH</strong> in the Mac app or from the CLI:
        </p>
        <CodeBlock>{`ssh user@100.x.y.z
spaces device pair --ssh user@100.x.y.z`}</CodeBlock>
        <p className={paragraphClass}>
          Pairing works with key-based SSH only; a password prompt cannot be answered. The device record stores the address you paired over first and the machine&apos;s other addresses after it, so the Mac reaches the machine over Tailscale wherever it is.
        </p>

        <h3 className={subheadingClass}>4. Pair your iPhone</h3>
        <ul className={listClass}>
          <li>• Keep Tailscale connected on the phone. Without it, the phone can reach the machine only from a network that routes to it directly.</li>
          <li>• On the Mac, open <strong>Settings → Devices</strong>, find the remote machine&apos;s row, and press <strong>Pair iPhone</strong>. The QR code lists the addresses it carries; the machine&apos;s Tailscale address is among them. Scan it with the Spaces iOS app.</li>
          <li>• Without a Mac in the loop, run <InlineCode>spaces device pair</InlineCode> on the machine itself. It prints a <InlineCode>spaces://pair</InlineCode> link to open on the phone.</li>
          <li>• The Mac only hands over the credential. Once paired, the phone connects to the machine on its own: the Mac can be asleep, closed, or on another continent. The Mac app&apos;s Devices list and the phone&apos;s device list both show which path a device is currently reached on, &quot;Local network&quot; or &quot;Tailscale&quot;.</li>
        </ul>

        <h3 className={subheadingClass}>Firewall and access policy</h3>
        <ul className={listClass}>
          <li>• No public ingress rule is needed for TCP <InlineCode>22</InlineCode> or <InlineCode>47847</InlineCode>. A cloud VM with both closed to the internet is the intended end state.</li>
          <li>• The tailnet&apos;s access policy has to allow your Mac and phone to reach the machine on TCP <InlineCode>47847</InlineCode>, and the Mac on TCP <InlineCode>22</InlineCode> as well, for pairing, SSH-driven updates, browser sessions, and the external editor. The default policy allows everything between your own devices.</li>
          <li>• A host firewall on the machine (<InlineCode>ufw</InlineCode>, <InlineCode>nftables</InlineCode>) has to accept those ports on the Tailscale interface, <InlineCode>tailscale0</InlineCode>.</li>
          <li>• The machine needs outbound connectivity for Tailscale itself; see{" "}
            <Link href={tailscaleFirewallURL} className="text-accent hover:underline" target="_blank" rel="noopener noreferrer">
              Tailscale&apos;s firewall requirements
            </Link>
            . Cloud VMs allow this by default.</li>
        </ul>
      </Section>

      <Section title="Using a public address instead">
        <Prose>
          You can pair a cloud VM over its public address, with ingress rules allowing TCP <InlineCode>22</InlineCode> and <InlineCode>47847</InlineCode> from the addresses you connect from. Understand what that setup does and does not fix before relying on it.
        </Prose>
        <ul className={listClass}>
          <li>• A reserved static IP keeps the <em>machine&apos;s</em> address stable. It does nothing for the <em>client&apos;s</em> address, which changes every time your Mac or phone joins a different network. An allowlist built around the address you had at home stops matching the moment you leave it.</li>
          <li>• Cellular carriers and many public networks put clients behind shared, shifting addresses, so an allowlist cannot be kept current by hand.</li>
          <li>• Opening <InlineCode>47847</InlineCode> to the whole internet makes the address reachable everywhere, at the cost of exposing the daemon&apos;s listener to everyone. The daemon authenticates every client, and it is still not the recommended answer to an unreachable device; Tailscale is.</li>
          <li>• A device paired over its public address gains the Tailscale path automatically once the machine has one: clients learn the daemon&apos;s current addresses on every connection. That only helps if the public path still works at that moment. If it is already unreachable, pair again over the Tailscale address as described under <strong>Moving a device off its public address</strong> below.</li>
        </ul>
      </Section>

      <Section title="What to expect on restrictive networks">
        <ul className={listClass}>
          <li>• When two devices cannot reach each other directly, Tailscale relays the encrypted connection through its DERP servers over HTTPS. A relayed connection is a working connection: Spaces behaves the same, with somewhat higher latency. <InlineCode>tailscale status</InlineCode> on the machine shows whether a peer is direct or relayed.</li>
          <li>• Public Wi-Fi with a captive portal blocks everything until you complete the sign-in page. Spaces shows the device as unreachable until then and reconnects on its own afterwards.</li>
          <li>• A network that blocks Tailscale&apos;s outbound traffic altogether keeps the machine out of reach while you are on it. No setup makes every network work.</li>
          <li>• Moving between networks costs one slower connection while the client re-races the machine&apos;s addresses; it then sticks to the one that answered. The Mac app reconnects immediately when its own network changes, and the iOS app re-checks the local path each time it returns to the foreground.</li>
        </ul>
      </Section>

      <Section title="Losing the connection is not the same as stopping the work">
        <Prose>
          Everything you run on the machine lives in its Spaces daemon, not in the client that opened it. A Mac that sleeps or a phone that loses signal disconnects a viewer; the terminal, the process, or the coding agent keeps running and is there when the client comes back. What does end the work is the machine itself stopping: shutting down or rebooting the VM ends every process on it, and the daemon that comes back after a reboot starts with nothing running.
        </Prose>
        <p className={paragraphClass}>
          For that to hold, three things have to come back on their own after a reboot, and the checks under <strong>Verify</strong> below confirm each one: <InlineCode>tailscaled</InlineCode>, the <InlineCode>spacesd.service</InlineCode> user service, and lingering for your account, without which systemd stops user services when your last SSH session ends. Keep an out-of-band way in as well (the cloud provider&apos;s console or its SSH tunnel), so a Tailscale outage or an expired key never locks you out of your own machine.
        </p>
      </Section>

      <Section title="Verify">
        <h3 className={subheadingClass}>On the machine</h3>
        <CodeBlock>{`tailscale status
tailscale ip -4
systemctl is-enabled tailscaled
systemctl is-active tailscaled
systemctl --user is-enabled spacesd.service
systemctl --user is-active spacesd.service
loginctl show-user "$USER" -p Linger`}</CodeBlock>
        <p className={paragraphClass}>
          Expect <InlineCode>enabled</InlineCode>, <InlineCode>active</InlineCode>, and <InlineCode>Linger=yes</InlineCode>.
        </p>

        <h3 className={subheadingClass}>On the Mac</h3>
        <p className={paragraphClass}>
          Substitute the machine&apos;s Tailscale address and your Linux username. Configure key-based SSH first; the second line fails if a prompt would be needed, which is exactly what pairing cannot handle.
        </p>
        <CodeBlock>{`ssh user@100.x.y.z
ssh -o BatchMode=yes user@100.x.y.z true
nc -z -G 10 100.x.y.z 47847
spaces device pair --ssh user@100.x.y.z
spaces device list`}</CodeBlock>
        <p className={paragraphClass}>
          <InlineCode>spaces device list</InlineCode> shows the address each device is reached on and every address it can fall back to. A reachable port is not the final check: open the remote project in Spaces and start a terminal in one of its workspaces.
        </p>

        <h3 className={subheadingClass}>Then, the behavior you actually care about</h3>
        <ul className={listClass}>
          <li>• Move the Mac to a different network (a phone hotspot is enough) and confirm the device reconnects and the terminal is still there.</li>
          <li>• Turn off Wi-Fi on the iPhone and open the same remote workspace over cellular.</li>
          <li>• Put the Mac to sleep and confirm the phone still reaches the machine.</li>
          <li>• Start a harmless long-running command in a Spaces terminal, disconnect the client, reconnect, and confirm the command ran on without it.</li>
        </ul>
      </Section>

      <Section title="Moving a device off its public address">
        <Prose>
          A machine paired over a public address that has since become unreachable is repaired by pairing it again over its Tailscale address. On the Mac, use <strong>Add remote device over SSH</strong> with the Tailscale address as the host, or run <InlineCode>spaces device pair --ssh user@100.x.y.z</InlineCode>. The daemon&apos;s identity has not changed, so this updates the existing device rather than adding a second one: its projects, workspaces, and sessions stay exactly as they were, and the Tailscale address now leads the list of addresses the Mac tries.
        </Prose>
        <p className={paragraphClass}>
          On the phone, scan the machine&apos;s QR code again from <strong>Settings → Devices</strong> on the Mac. A rescan of a device the phone already knows updates that device&apos;s addresses in place.
        </p>
      </Section>

      <Section title="Troubleshooting">
        <Prose>
          &quot;Device unreachable&quot; has a short list of causes. Work down it in order; each check rules out the ones above it.
        </Prose>
        <ul className={listClass}>
          <li>• <strong>The machine is stopped.</strong> Check the cloud console. A stopped VM answers nothing, on any address.</li>
          <li>• <strong>Tailscale is down or the key expired.</strong> <InlineCode>tailscale status</InlineCode> on the machine, and the admin console for an expired node. Re-authenticate with <InlineCode>tailscale up</InlineCode> if it is signed out.</li>
          <li>• <strong>Wrong tailnet or a blocking access policy.</strong> The Mac, the phone, and the machine have to be signed into the same tailnet, and the policy has to allow TCP <InlineCode>47847</InlineCode> to the machine.</li>
          <li>• <strong>SSH fails.</strong> A password prompt, a missing key, or a changed host key on a rebuilt VM (replace the stale <InlineCode>known_hosts</InlineCode> entry). A failing SSH connection breaks pairing, SSH-driven updates, and the Mac&apos;s browser sessions and external editor for that device. Terminals, coding agents, and the built-in Editor do not use it, so if those still work the device itself is reachable.</li>
          <li>• <strong>The Spaces service is stopped.</strong> <InlineCode>systemctl --user status spacesd.service</InlineCode> on the machine; restart it with <InlineCode>systemctl --user restart spacesd.service</InlineCode>.</li>
          <li>• <strong>Port 47847 does not answer.</strong> <InlineCode>nc -z -G 10 ADDRESS 47847</InlineCode> from the Mac. If SSH to the same address works, the service is active, and this still fails, a host firewall on the machine is dropping the port.</li>
          <li>• <strong>Client and daemon speak different protocol versions.</strong> Spaces refuses the connection and says which side is behind. Update the Mac app, or the daemon as described under <strong>Linux</strong> on the Installation page. Releases that share a protocol version connect fine, so a differing version number on its own is not the cause.</li>
          <li>• <strong>The device still points at a public address.</strong> <InlineCode>spaces device list</InlineCode> shows no Tailscale address for it. Pair it again as described above.</li>
        </ul>
      </Section>
    </DocsShell>
  );
}
