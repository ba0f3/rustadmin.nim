import asyncdispatch

type
  SendCommand* = proc(command: string, id = -1): Future[void]