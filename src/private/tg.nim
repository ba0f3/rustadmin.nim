import telebot, asyncdispatch, json, strformat, strutils, chronicles

const MAX_CHAT_MESSAGE_SIZE = 4000

type
  Telegram* = object
    syncChat*: bool
    botApi*: string
    chatId*: int64
    chatTitle*: string

var
  config: Telegram
  buffer: seq[string]
  bot: TeleBot


proc syncChatMessages() {.async.} =
  var content: string
  while true:
    if buffer.len <= 0:
      break
    if content.len + buffer[0].len < MAX_CHAT_MESSAGE_SIZE:
      content.add(buffer[0])
      content.add("\n")
      buffer.del(0)

  if content.len > 0:
    try:
      var message = newMessage(config.chatId, content)
      message.disableNotification = true
      message.parseMode = "html"
      bot.send(message)
    except:
      let e = getCurrentException()
      error "Cannot send message to Telegram", name=e.name, message=e.msg

proc loop() {.async.} =
  while config.syncChat:
    await syncChatMessages()
    await sleepAsync(1000)


proc initTelegram*(cfg: Telegram) {.async.} =
  config = cfg
  bot = newTeleBot(config.botApi)

  asyncCheck loop()

proc addMessage*(message: string) {.async.} =
  try:
    let
      node = parseJson(message)
      suffix = if node["Channel"].getInt == 1: "#" else: ""
      name = node["Username"].getStr
      text = node["Message"].getStr.replace("<", "&lt;").replace(">", "&gt;")
    buffer.add(fmt"{name}{suffix}: {text}")
  except:
    let e = getCurrentException()
    error "Exception caught", name=e.name, message=e.msg

proc updatePlayerOnline*(online, max: int) {.async.} =
  let title = fmt"{config.chatTitle} [{online}/{max}]"
  try:
    discard await bot.setChatTitle($config.chatId, title)
  except:
    let e = getCurrentException()
    error "Cannot set chat title", name=e.name, message=e.msg