export class GatewayError extends Error {
  readonly statusCode: number;

  constructor(message: string, statusCode = 500) {
    super(message);
    this.name = "GatewayError";
    this.statusCode = statusCode;
  }
}

export function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}
