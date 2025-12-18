import type { Request } from "express";

export type RawBodyRequest = Request & {
  rawBody?: Buffer;
};

export function captureRawBody(req: RawBodyRequest, _res: any, buf: Buffer) {
  // store raw bytes as-is (signature depends on it)
  req.rawBody = buf;
}
