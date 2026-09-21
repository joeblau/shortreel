import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  metadataBase: new URL("https://blau.app"),
  alternates: { canonical: "/shotreel" },
  title: "ShortReel — A workspace for your next idea",
  description:
    "Bring your iPhones into one Mac workspace. Prepare your devices, configure slideshows, and create content drafts with ShortReel.",
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
