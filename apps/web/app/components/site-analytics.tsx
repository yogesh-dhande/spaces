"use client";

import posthog from "posthog-js";
import { useEffect } from "react";

const posthogProjectKey = "phc_pxcBaHNB9tX4tASjeJ6EQvNDPoagWnfCRujHRS9TZaiA";

/**
 * Every Download link on the site funnels through here, so this is the single
 * place a future ad-platform conversion call (a Google Ads `AW-` tag) belongs.
 */
export function trackDownloadClick(placement: string, destinationURL: string) {
  // sendBeacon survives the navigation the click triggers (links open the
  // GitHub releases page).
  posthog.capture(
    "download_clicked",
    { placement, destination_url: destinationURL },
    { transport: "sendBeacon", send_instantly: true },
  );
}

function visitorOptedOut() {
  const doNotTrack = (window as { doNotTrack?: string }).doNotTrack;
  const globalPrivacyControl = (navigator as { globalPrivacyControl?: boolean })
    .globalPrivacyControl;
  return (
    navigator.doNotTrack === "1" ||
    doNotTrack === "1" ||
    globalPrivacyControl === true
  );
}

// `click` does not fire for a middle-click, which opens the link in a new tab,
// so `auxclick` is also handled. Only its middle button navigates; a
// right-click opens a menu.
function handleClick(event: MouseEvent) {
  if (event.type === "auxclick" && event.button !== 1) return;
  if (!(event.target instanceof Element)) return;
  const link = event.target.closest<HTMLAnchorElement>("a[data-download-placement]");
  if (!link) return;
  trackDownloadClick(link.dataset.downloadPlacement ?? "unknown", link.href);
}

/**
 * Cookieless PostHog: pageviews plus `download_clicked`. Nothing runs, and no
 * listener is attached, when the browser signals Do Not Track or Global
 * Privacy Control. Initialization happens in an effect so the static export
 * never executes PostHog.
 */
export function SiteAnalytics() {
  useEffect(() => {
    if (visitorOptedOut()) return;

    posthog.init(posthogProjectKey, {
      api_host: "https://us.i.posthog.com",
      cookieless_mode: "always",
      autocapture: false,
      capture_pageview: "history_change",
      capture_pageleave: false,
      disable_session_recording: true,
      disable_surveys: true,
      capture_heatmaps: false,
      capture_dead_clicks: false,
      capture_exceptions: false,
      capture_performance: false,
      // Skips the remote config / feature flag request on load.
      advanced_disable_flags: true,
      disable_external_dependency_loading: true,
    });

    document.addEventListener("click", handleClick);
    document.addEventListener("auxclick", handleClick);
    return () => {
      document.removeEventListener("click", handleClick);
      document.removeEventListener("auxclick", handleClick);
    };
  }, []);

  return null;
}
