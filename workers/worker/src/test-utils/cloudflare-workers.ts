export class DurableObject<Environment = unknown> {
  constructor(
    protected readonly ctx: unknown,
    protected readonly env: Environment,
  ) {}
}
