/**
 * Plays a short ascending two-tone chime using the Web Audio API.
 * Used to signal that the AI chat session is connected and ready to listen.
 * No external audio files required.
 */
export function playReadyChime() {
  const ctx = new AudioContext();
  const gain = ctx.createGain();
  gain.connect(ctx.destination);

  const osc = ctx.createOscillator();
  osc.type = "sine";
  osc.connect(gain);

  const now = ctx.currentTime;

  // Short ascending two-tone chime (C5 -> E5)
  osc.frequency.setValueAtTime(523, now); // C5
  osc.frequency.setValueAtTime(659, now + 0.15); // E5

  gain.gain.setValueAtTime(0.3, now);
  gain.gain.exponentialRampToValueAtTime(0.01, now + 0.3);

  osc.start(now);
  osc.stop(now + 0.3);

  // Clean up the AudioContext after the chime finishes
  setTimeout(() => {
    ctx.close().catch(() => {});
  }, 500);
}
