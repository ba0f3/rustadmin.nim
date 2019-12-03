import json, ws, asyncdispatch, sim, strformat, tables, json, strutils, httpclient, pegs, chronicles

import private/tg

const
  SERVER_INFO = 1000
  PLAYER_LIST = 1001


type
  AntiCheat = object
    numberOfVacBans: int
    daysSinceLastBan: int

  Config = object
    autoReconnect: bool
    debug: bool
    steamApiKey: string
    rconAddress: string
    rconPassword: string
    anticheat: seq[AntiCheat]
    tg: Telegram

  Callback = proc(node: JsonNode): Future[void]



let
  PLAYER_JOINED_MESSAGE = peg"^{(\d+\.?)+}\:\d+\/{\d+}\/{@}' joined ['{\letter+}\/$2\]$"
  #PLAYER_ENTERED_MESSAGE = peg"^{\letter+}\[\d+\/{\d+}\]' has entered the game'"
  GET_PLAYER_BANS = "http://api.steampowered.com/ISteamUser/GetPlayerBans/v1/?key=$#&steamids=$#"

var
  config: Config
  s: WebSocket
  callbacks = initTable[int, Callback]()

proc sendCmd(cmd: string, id = -1) {.async.} =
  debug "Execute RCON command", cmd
  await s.send("{\"Identifier\":" & $id & ",\"Message\":\"" & cmd & "\",\"Name\":\"rustadm.nim\"}")

proc checkVACBan*(steamId: string) {.async.} =
  let
    endpoint = GET_PLAYER_BANS % [config.steamApiKey, steamId]
    client = newAsyncHttpClient()
    data = await client.getContent(endpoint)
    node = parseJson(data)
  if node["players"].len == 0:
    return
  for player in node["players"].items:
    if player["VACBanned"].getBool:
      let
        steamId = player["SteamId"].getStr
        numberOfVacBans = player["NumberOfVACBans"].getInt
        daysSinceLastBan = player["DaysSinceLastBan"].getInt
      for ac in config.anticheat:
        if numberOfVacBans >= ac.numberOfVacBans:
          info "Autoban user", steamId
          if ac.daysSinceLastBan <= 0:
            await sendCmd(fmt"banid {steamId} Player VAC bans ({numberOfVacBans}) >= {ac.daysSinceLastBan}")
            break
          elif daysSinceLastBan < ac.daysSinceLastBan:
            await sendCmd(fmt"banid {steamId} Player days since last VAC bans ({daysSinceLastBan}) < {ac.daysSinceLastBan}")
            break
          else:
            discard

proc checkVACBan*(steamIds: seq[string]) {.async.} =
  var steamIds = steamIds
  if steamIds.len > 99:
    var temp: seq[string]
    while steamIds.len > 99:
      temp.add(steamIds.pop())
      if temp.len > 99:
        await checkVACBan(steamIds.join(","))
        temp = @[]
  await checkVACBan(steamIds.join(","))


proc onServerInfo(info: JsonNode) {.async.} =
  let
    players = info["Players"].getInt
    maxPlayers = info["MaxPlayers"].getInt
  await updatePlayerOnline(players, maxPlayers)

proc updatePlayerCount() {.async.} =
  while true:
    await sleepAsync(10 * 1_000)
    await sendCmd("serverinfo", SERVER_INFO)

proc onPlayerList(node: JsonNode) {.async.} =
  if node.len == 0:
    return
  info "Checking VAC Bans for existing players", count=node.len
  var ids: seq[string]
  for player in node.items:
    ids.add(player["SteamID"].getStr)
  await checkVACBan(ids)


proc onConnect() {.async.} =
  info "Connected"
  await sendCmd("playerlist", PLAYER_LIST)
  asyncCheck updatePlayerCount()

proc onChat(message: string) {.async.} =
  if config.tg.syncChat:
    asyncCheck addMessage(message)

proc onMessage(data: JsonNode) {.async.} =
  try:
    let id = data["Identifier"].getInt
    if callbacks.hasKey(id):
      let message = parseJson(data["Message"].getStr)
      await callbacks[id](message)
    else:
      let message = data["Message"].getStr
      if message =~ PLAYER_JOINED_MESSAGE:
        info "Checking VAC Bans for new player", name=matches[2], steamId=matches[1], ip=matches[0]
        await checkVACBan(matches[1])
  except KeyError:
    let e = getCurrentException()
    error "Exception caught", name=e.name, message=e.msg

proc connect() {.async.} =
  while true:
    try:
      s = await newWebSocket(fmt"ws://{config.rconAddress}/{config.rconPassword}")
      await onConnect()
      break
    except OSError, IOError:
      debug "Connection error, retry after 2s.."
      await sleepAsync(2000)

proc main() {.async.} =
  asyncCheck initTelegram(config.tg)

  callbacks[SERVER_INFO] = onServerInfo
  callbacks[PLAYER_LIST] = onPlayerList


  info "Starting"
  await connect()
  while true:
    if s.readyState == Open:
      debug "Waiting for messages"
      try:
        let
          packet = await s.receiveStrPacket()
          message = parseJson(packet)
        #echo message["Type"].getStr, packet
        if message["Type"].getStr == "Chat":
          await onChat(message["Message"].getStr)
        else:
          await onMessage(message)
      except JsonParsingError:
        let e = getCurrentException()
        error "Exception caught", name=e.name, message=e.msg
      except WebSocketError:
        error "Connection closed"
        s.readyState = Closed
    elif s.readyState == Closed and config.autoReconnect:
      info "Reconnecting"
      await connect()


when isMainModule:
  config = to[Config]("config.ini")

  if config.debug:
    setLogLevel(DEBUG)
  else:
    setLogLevel(INFO)

  waitFor main()
