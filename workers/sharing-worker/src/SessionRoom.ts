export class SessionRoom {
  constructor(private state: DurableObjectState, private env: unknown) {}
  async fetch(request: Request): Promise<Response> {
    return new Response("not implemented", { status: 501 });
  }
}
