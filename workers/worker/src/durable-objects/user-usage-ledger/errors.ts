export class InsufficientAllowanceError extends Error {
  readonly code = "INSUFFICIENT_ALLOWANCE" as const;

  constructor(message = "Trial credits are exhausted") {
    super(message);
    this.name = "InsufficientAllowanceError";
    Object.setPrototypeOf(this, InsufficientAllowanceError.prototype);
  }

  /**
   * Duck-typed check that survives the Durable Object RPC boundary, where a
   * thrown error's subclass identity is not preserved on the caller side.
   */
  static isInstance(err: unknown): err is InsufficientAllowanceError {
    if (err instanceof InsufficientAllowanceError) return true;
    return (
      typeof err === "object" &&
      err !== null &&
      (err as { name?: unknown }).name === "InsufficientAllowanceError"
    );
  }
}

export class ReservationNotFoundError extends Error {
  readonly code = "RESERVATION_NOT_FOUND" as const;
  readonly reservationId: string;

  constructor(reservationId: string) {
    super(`Reservation not found: ${reservationId}`);
    this.name = "ReservationNotFoundError";
    this.reservationId = reservationId;
    Object.setPrototypeOf(this, ReservationNotFoundError.prototype);
  }

  static isInstance(err: unknown): err is ReservationNotFoundError {
    if (err instanceof ReservationNotFoundError) return true;
    return (
      typeof err === "object" &&
      err !== null &&
      (err as { name?: unknown }).name === "ReservationNotFoundError"
    );
  }
}

export type ReservationStatus = "pending" | "committed" | "released";

export class ReservationStateError extends Error {
  readonly code = "RESERVATION_STATE_ERROR" as const;
  readonly reservationId: string;
  readonly currentStatus: ReservationStatus;
  readonly attemptedOperation: "commit" | "release";

  constructor(
    reservationId: string,
    currentStatus: ReservationStatus,
    attemptedOperation: "commit" | "release",
  ) {
    super(
      `Cannot ${attemptedOperation} reservation ${reservationId}: it is already ${currentStatus}`,
    );
    this.name = "ReservationStateError";
    this.reservationId = reservationId;
    this.currentStatus = currentStatus;
    this.attemptedOperation = attemptedOperation;
    Object.setPrototypeOf(this, ReservationStateError.prototype);
  }

  static isInstance(err: unknown): err is ReservationStateError {
    if (err instanceof ReservationStateError) return true;
    return (
      typeof err === "object" &&
      err !== null &&
      (err as { name?: unknown }).name === "ReservationStateError"
    );
  }
}
