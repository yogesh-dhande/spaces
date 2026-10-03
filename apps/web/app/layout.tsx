import type { Metadata } from "next";
import "./globals.css";
import { SiteAnalytics } from "./components/site-analytics";

export const metadata: Metadata = {
  title: {
    default: "Spaces: coding agents you can reach from anywhere",
    template: "%s | Spaces",
  },
  metadataBase: new URL("https://usespaces.dev"),
  description: "Run Claude Code, Codex, and opencode on a Mac or Linux server, check on them from your Mac or iPhone, and let them work together across harnesses. Free on Mac and Linux.",
  openGraph: { type: "website", siteName: "Spaces", locale: "en_US" },
  twitter: { card: "summary_large_image" },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body className="antialiased">
        {children}
        <SiteAnalytics />
      </body>
    </html>
  );
}
