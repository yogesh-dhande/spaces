import type { Metadata } from "next";
import Link from "next/link";
import { CodeBlock, InlineCode } from "../components/code-block";
import { DocLink } from "../components/doc-link";
import { DocsShell } from "../components/docs-shell";
import { Prose, Section, SubHeading } from "../components/section";

const tailscaleInstallURL = "https://tailscale.com/kb/1017/install";
const tailscaleFirewallURL = "https://tailscale.com/kb/1082/firewall-ports";
const tailscaleKeyExpiryURL = "https://tailscale.com/kb/1028/key-expiry";

const listClass = "mt-3 space-y-2 text-sm leading-7 text-foreground-soft";
const paragraphClass = "mt-3 text-sm leading-7 text-foreground-soft";

export const metadata: Metadata = {
  title: "Remote machines",
  description:
    "Install Spaces on a Linux machine or another Mac, pair it, and reach it from anywhere.",
};

export default function RemoteAccessDocsPage() {
  return (
    <DocsShell
      title="Remote machines"
      description="Install Spaces on a Linux machine or another Mac, pair it, and reach it from anywhere."
      pagePath="/docs/remote-access"
    >
      <Section title="What a remote machine is">
        <Prose>
          A remote machine is another Mac or a Linux machine running Spaces. It gets its own section in
          the sidebar, alongside &ldquo;Local&rdquo; for this Mac, once paired.
        </Prose>
        <SubHeading id="disconnect-vs-stop">Losing the connection is not the same as stopping the work</SubHeading>
        <p className={paragraphClass}>
          Everything you run on a remote machine lives in the Spaces service on that machine, not in the
          client that opened it. A Mac that sleeps or a phone that loses signal disconnects a viewer; the
          terminal, the process, or the coding agent keeps running and is there when the client comes
          back. What ends the work is the machine itself stopping: shutting down or rebooting it ends
          every session on it, and it starts with nothing running afterward.
        </p>
      </Section>

      <Section id="install-on-linux" title="Install on Linux">
        <Prose>
          On the Linux machine, install the latest release:
        </Prose>
        <CodeBlock>{`curl -fsSL https://usespaces.dev/install.sh | bash`}</CodeBlock>
        <p className={paragraphClass}>
          The installer registers <InlineCode>spacesd.service</InlineCode> as a systemd user service and
          starts it, and enables lingering (<InlineCode>loginctl enable-linger</InlineCode>) so it keeps
          running after you disconnect, without a login session open. Ubuntu 24.04 on x86_64 or arm64 is
          supported.
        </p>
        <p className={paragraphClass}>
          To pair another Mac instead, install the Mac app there the same way you installed it on this
          one; see <DocLink href="/docs/installation">Install on your Mac</DocLink>.
        </p>
      </Section>

      <Section id="update-and-uninstall-on-linux" title="Update and uninstall on Linux">
        <SubHeading>Update</SubHeading>
        <Prose>
          Re-run the install command with a specific version to update in place, replacing{" "}
          <InlineCode>&lt;version&gt;</InlineCode> with a released version such as{" "}
          <InlineCode>0.1.0</InlineCode>:
        </Prose>
        <CodeBlock>{`curl -fsSL https://usespaces.dev/install.sh | bash -s -- <version>`}</CodeBlock>
        <p className={paragraphClass}>
          The Mac app and the <InlineCode>spaces</InlineCode> CLI print this command with the right
          version already filled in whenever they reach a Linux machine that is behind. Terminals,
          processes, and coding agents keep running across the update. For a machine paired over SSH,
          the Mac app also offers an &ldquo;Update over SSH&rdquo; action that runs the same command for
          you.
        </p>
        <SubHeading>Uninstall</SubHeading>
        <Prose>On the Linux machine:</Prose>
        <CodeBlock>{`systemctl --user disable --now spacesd.service
rm -f ~/.config/systemd/user/spacesd.service
systemctl --user daemon-reload
rm -f ~/.local/bin/spaces
rm -rf ~/.spaces ~/spaces`}</CodeBlock>
        <Prose>
          <InlineCode>~/.spaces</InlineCode> holds the local database; <InlineCode>~/spaces</InlineCode>{" "}
          holds its repos and workspace worktrees. Leave them alone if you want to keep that state.
        </Prose>
      </Section>

      <Section id="pairing" title="Pairing">
        <SubHeading id="pair-a-remote-machine">Pair a remote machine</SubHeading>
        <Prose>
          On the Mac, open Settings → Devices → &ldquo;Add remote device over SSH&rdquo; and enter the
          host; an &ldquo;Advanced&rdquo; disclosure adds the user and port. Or from the CLI:
        </Prose>
        <CodeBlock>{`spaces device pair --ssh user@host`}</CodeBlock>
        <p className={paragraphClass}>
          SSH has to work with no prompts: key-based access (or an unlocked SSH agent), and the
          machine&apos;s host key already recorded. Connect to it once by hand (
          <InlineCode>ssh user@host</InlineCode>) to record the key, verifying its fingerprint
          through the cloud console or another trusted channel before accepting it.
        </p>
        <SubHeading id="pair-your-iphone">Pair your iPhone</SubHeading>
        <Prose>
          On the Mac, find the device&apos;s row in Settings → Devices and press &ldquo;Pair
          iPhone&rdquo; for its QR code; scan it with the Spaces iOS app. Without a Mac in the loop, run{" "}
          <InlineCode>spaces device pair</InlineCode> on the machine itself, which prints a{" "}
          <InlineCode>spaces://pair</InlineCode> link to open on the phone.
        </Prose>
        <p className={paragraphClass}>
          Pairing links are short-lived and single-use. Both sides also need compatible Spaces versions
          to pair; update whichever is older.
        </p>
      </Section>

      <Section id="connections" title="How the connection works">
        <Prose>
          Pairing over SSH uses SSH once, to fetch the pairing details; pairing by QR code or a{" "}
          <InlineCode>spaces://pair</InlineCode> link does not use SSH at all. After pairing, your Mac or
          iPhone connects directly to the machine&apos;s Spaces service on port{" "}
          <InlineCode>47847</InlineCode>. A paired device carries a short list of addresses: an SSH
          pairing puts the SSH host name first, ahead of the addresses the machine itself reports (local
          network, then its Tailscale address when it has one); a QR-code or link pairing carries just
          those reported addresses, in that order. Each client tries them in order, keeps whichever
          answers, and learns the current addresses again on every connection, which is what lets one
          pairing follow you between networks.
        </Prose>
        <p className={paragraphClass}>
          Spaces remembers the machine&apos;s identity at pairing and refuses to connect to a machine
          that does not match it, even if something else answers on the same address.
        </p>
      </Section>

      <Section id="tailscale" title="Tailscale">
        <Prose>
          Put the remote machine, your Mac, and your iPhone on one tailnet and pair using the
          machine&apos;s Tailscale address. The address stays the same on every network you move to, and
          nothing has to be opened to the public internet.
        </Prose>
        <SubHeading>1. Install Tailscale</SubHeading>
        <p className={paragraphClass}>
          Follow the{" "}
          <Link
            href={tailscaleInstallURL}
            className="text-accent hover:underline"
            target="_blank"
            rel="noopener noreferrer"
          >
            official installation instructions
          </Link>{" "}
          on the machine, your Mac, and your iPhone, and sign each into the same tailnet. On the
          machine, confirm it is up and note its address:
        </p>
        <CodeBlock>{`tailscale status
tailscale ip -4`}</CodeBlock>
        <p className={paragraphClass}>
          On a Linux machine, confirm Tailscale itself starts at boot (
          <InlineCode>systemctl is-enabled tailscaled</InlineCode>).
          Node keys expire by default; for a machine you plan to leave running, disable key expiry for
          it in the Tailscale admin console (see{" "}
          <Link
            href={tailscaleKeyExpiryURL}
            className="text-accent hover:underline"
            target="_blank"
            rel="noopener noreferrer"
          >
            key expiry
          </Link>
          ).
        </p>
        <SubHeading>2. Install Spaces on the machine</SubHeading>
        <p className={paragraphClass}>
          See <DocLink href="/docs/remote-access#install-on-linux">Install on Linux</DocLink> above, or
          install the Mac app on a second Mac.
        </p>
        <SubHeading>3. Pair your Mac over the Tailscale address</SubHeading>
        <p className={paragraphClass}>
          Connect over SSH once by hand so the machine&apos;s host key is recorded, then pair using the
          Tailscale address (or its MagicDNS name) as the host:
        </p>
        <CodeBlock>{`ssh user@100.x.y.z
spaces device pair --ssh user@100.x.y.z`}</CodeBlock>
        <SubHeading>4. Pair your iPhone</SubHeading>
        <p className={paragraphClass}>
          Keep Tailscale connected on the phone, then follow{" "}
          <DocLink href="/docs/remote-access#pair-your-iphone">Pair your iPhone</DocLink> above. Its QR
          code lists the machine&apos;s Tailscale address alongside the others.
        </p>
        <SubHeading>Firewall and access policy</SubHeading>
        <ul className={listClass}>
          <li>
            • No public ingress rule is needed for TCP <InlineCode>22</InlineCode> or{" "}
            <InlineCode>47847</InlineCode>. A machine with both closed to the internet is the intended
            end state.
          </li>
          <li>
            • The tailnet&apos;s access policy has to allow your Mac and phone to reach the machine on
            TCP <InlineCode>47847</InlineCode>, and the Mac on TCP <InlineCode>22</InlineCode> as well.
            The default policy allows everything between your own devices.
          </li>
          <li>
            • On a Linux machine, a host firewall has to accept those ports on the Tailscale interface,{" "}
            <InlineCode>tailscale0</InlineCode>.
          </li>
          <li>
            • The machine needs outbound connectivity for Tailscale itself; see{" "}
            <Link
              href={tailscaleFirewallURL}
              className="text-accent hover:underline"
              target="_blank"
              rel="noopener noreferrer"
            >
              Tailscale&apos;s firewall requirements
            </Link>
            .
          </li>
        </ul>
      </Section>

      <Section id="public-address" title="Public address">
        <Prose>
          You can pair a machine over its public address instead, with ingress rules allowing TCP{" "}
          <InlineCode>22</InlineCode> and <InlineCode>47847</InlineCode> from the addresses you connect
          from.
        </Prose>
        <ul className={listClass}>
          <li>
            • A reserved static IP keeps the machine&apos;s address stable, but not the client&apos;s: an
            allowlist built around the address you had at home stops matching once you leave it, and
            cellular networks put clients behind shifting addresses an allowlist cannot track.
          </li>
          <li>
            • Opening <InlineCode>47847</InlineCode> to the whole internet makes the address reachable
            everywhere, at the cost of exposing that port to everyone. Every client is still
            authenticated, but Tailscale is the setup this page recommends.
          </li>
        </ul>
        <SubHeading>What to expect on restrictive networks</SubHeading>
        <ul className={listClass}>
          <li>
            • When two devices cannot reach each other directly, Tailscale relays the connection. A
            relayed connection still works, with somewhat higher latency.
          </li>
          <li>• Public Wi-Fi with a captive portal blocks everything until you complete its sign-in page.</li>
          <li>
            • Moving between networks costs one slower connection while the client re-races the
            machine&apos;s addresses, then sticks to the one that answered.
          </li>
        </ul>
        <SubHeading>Moving a device off its public address</SubHeading>
        <p className={paragraphClass}>
          Pair the machine again over its Tailscale address, using &ldquo;Add remote device over
          SSH&rdquo; or <InlineCode>spaces device pair --ssh user@100.x.y.z</InlineCode>. The
          machine&apos;s identity has not changed, so this updates the existing device rather than adding
          a second one: its projects, workspaces, and sessions stay as they were, and the Tailscale
          address becomes the one the Mac tries first. On the phone, scan the machine&apos;s QR code
          again from Settings → Devices on the Mac.
        </p>
      </Section>

      <Section id="removing-a-device" title="Renaming and removing">
        <Prose>
          A device row&apos;s menu offers &ldquo;Rename…&rdquo; and &ldquo;Remove Device…&rdquo;. Removing
          asks first: &ldquo;Its projects, workspaces, and running terminals stay on &lt;device&gt; and
          keep running. This Mac deletes the pairing and its stored credential, and stops listing that
          device. Pair it again to get it back.&rdquo;
        </Prose>
      </Section>

      <Section id="troubleshooting" title="Troubleshooting">
        <Prose>
          A device shown as unreachable has a short list of causes. Work down it in order; each check
          rules out the ones above it.
        </Prose>
        <ul className={listClass}>
          <li>• <strong>The machine is stopped or asleep.</strong> Nothing answers on any address.</li>
          <li>
            • <strong>Tailscale is down or the key expired.</strong>{" "}
            <InlineCode>tailscale status</InlineCode> on the machine; re-authenticate with{" "}
            <InlineCode>tailscale up</InlineCode> if it is signed out.
          </li>
          <li>
            • <strong>The Spaces service is stopped.</strong> On Linux:{" "}
            <InlineCode>systemctl --user status spacesd.service</InlineCode> on the machine; restart it
            with <InlineCode>systemctl --user restart spacesd.service</InlineCode>. Also check lingering
            is on: <InlineCode>loginctl show-user &quot;$USER&quot; -p Linger</InlineCode> should read{" "}
            <InlineCode>Linger=yes</InlineCode>. On a remote Mac, open Spaces there.
          </li>
          <li>
            • <strong>Port 47847 does not answer.</strong>{" "}
            <InlineCode>nc -vz &lt;host&gt; 47847</InlineCode> from the Mac. If SSH to the same address
            works and the service is active, a host firewall on the machine is dropping the port.
          </li>
          <li>
            • <strong>The machine&apos;s identity changed</strong> (a rebuilt VM, a reinstalled OS).
            Re-pair the device.
          </li>
          <li>
            • <strong>The two sides are on incompatible versions.</strong> Spaces shows both versions and
            the fix; see <DocLink href="/docs/installation#updates">Updates</DocLink>.
          </li>
        </ul>
      </Section>
    </DocsShell>
  );
}
