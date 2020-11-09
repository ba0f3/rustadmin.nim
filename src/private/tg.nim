import telebot, asyncdispatch, json, strformat, strutils, chronicles, options
import types

const MAX_CHAT_MESSAGE_SIZE = 4000

type
  Telegram* = object
    syncChat*: bool
    botApi*: string
    chatId*: int64
    adminIds*: seq[int]
    chatTitle*: string

var
  config: Telegram
  sendRconCmd: SendCommand
  buffer: seq[string]
  bot: TeleBot
  lastOnline = 0

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
      discard await bot.sendMessage(config.chatId, content, disableNotification=true, disableWebpagePreview=true)
    except:
      let e = getCurrentException()
      error "Cannot send message to Telegram", name=e.name, message=e.msg

proc loop() {.async.} =
  while config.syncChat:
    await syncChatMessages()
    await sleepAsync(1000)


proc updateHandler(b: Telebot, u: Update): Future[bool] {.async, gcsafe.} =
  if u.message.isSome:
    let message = u.message.get
    if message.newChatTitle.isSome:
      discard await bot.deleteMessage($message.chat.id, message.messageId)
    elif message.text.isSome and message.fromUser.isSome:
      let
        chatId = message.chat.id
        userId = message.fromUser.get.id
        text = message.text.get
      if chatId == config.chatId and userId in config.adminIds:
        if text[0] == '~':
          await sendRconCmd("say " & text[1..<text.len], 1002)

proc commandHandler(bot: Telebot, command: Command): Future[bool] {.async, gcsafe.} =
  let message = command.message
  if message.text.isSome and message.fromUser.isSome:
    let
      chatId = message.chat.id
      userId = message.fromUser.get.id
    if chatId == config.chatId and userId in config.adminIds:
      if command.params.len != 0:
        await sendRconCmd(fmt"{command.command} {command.params}", 1002)
      else:
        await sendRconCmd(command.command, 1002)

proc initTelegram*(cfg: Telegram, sendCmd: SendCommand) {.async.} =
  config = cfg
  sendRconCmd = sendCmd
  bot = newTeleBot(config.botApi)
  bot.onUpdate(updateHandler)
  bot.catchallCommandCallback = commandHandler
  asyncCheck loop()
  asynccheck pollAsync(bot, clean = true)

proc addChatMessage*(message: string) {.async.} =
  try:
    let
      node = parseJson(message)
      suffix = if node["Channel"].getInt == 1: "#" else: ""
      name = node["Username"].getStr
      text = node["Message"].getStr
    buffer.add(fmt"{name}{suffix}: {text}")
  except:
    let e = getCurrentException()
    error "Exception caught", name=e.name, message=e.msg

proc addText*(text: string) {.async.} =
  buffer.add(text)

proc updatePlayerOnline*(online, max: int) {.async.} =
  if online == lastOnline:
    return
  lastOnline = online
  let title = fmt"{config.chatTitle} [{online}/{max}]"
  try:
    discard await bot.setChatTitle($config.chatId, title)
  except:
    let e = getCurrentException()
    error "Cannot set chat title", name=e.name, message=e.msg