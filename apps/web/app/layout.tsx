import type { Metadata } from "next";
import "./globals.css";
import { SiteAnalytics } from "./components/site-analytics";

export const metadata: Metadata = {
  title: {
    default: "Spaces",
    template: "%s | Spaces",
  },
  metadataBase: new URL("https://usespaces.dev"),
  description: "Manage parallel coding sessions, from anywhere, on any machine.",
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
