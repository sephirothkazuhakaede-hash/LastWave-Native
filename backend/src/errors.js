export class HttpError extends Error {
  constructor(statusCode, code, message, options = {}) {
    super(message, options);
    this.name = 'HttpError';
    this.statusCode = statusCode;
    this.code = code;
  }
}

export class ProcessError extends Error {
  constructor(message, { exitCode = null, stderr = '', timedOut = false, cause } = {}) {
    super(message, { cause });
    this.name = 'ProcessError';
    this.exitCode = exitCode;
    this.stderr = stderr;
    this.timedOut = timedOut;
  }
}
