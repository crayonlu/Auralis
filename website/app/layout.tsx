import type { Metadata } from "next";
import { Geist } from "next/font/google";
import { headers } from "next/headers";
import "./globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

export async function generateMetadata(): Promise<Metadata> {
  const requestHeaders = await headers();
  const host = requestHeaders.get("x-forwarded-host") ?? requestHeaders.get("host");
  const protocol =
    requestHeaders.get("x-forwarded-proto") ??
    (host?.startsWith("localhost") ? "http" : "https");
  const baseUrl = host ? `${protocol}://${host}` : "https://auralis.site";
  const title = "Auralis — Native music for macOS";
  const description =
    "A quiet, native NetEase Cloud Music player for macOS with synced lyrics and smart caching.";

  return {
    title,
    description,
    icons: {
      icon: "/brand-mark.png",
      apple: "/brand-mark.png",
    },
    openGraph: {
      title,
      description,
      type: "website",
      url: baseUrl,
      images: [
        {
          url: `${baseUrl}/og.png`,
          width: 1200,
          height: 630,
          alt: "Auralis — Your music. At home on Mac.",
        },
      ],
    },
    twitter: {
      card: "summary_large_image",
      title,
      description,
      images: [`${baseUrl}/og.png`],
    },
  };
}

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body className={geistSans.variable}>{children}</body>
    </html>
  );
}
