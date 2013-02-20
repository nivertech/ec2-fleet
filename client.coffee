makeRequest = ->
  stats.inproc++
  id = Math.random().toString(36).slice(2)
  req = http.request(
    host: config.host
    port: config.port
    agent: false
  )
  req.setNoDelay()
  req.on "response", (res) ->
    stats.inproc--
    stats.clients++
    clients[id] = req
    
    #res.setEncoding('utf8');
    #res.on('data', function (chunk) {
    #  console.log('BODY: ' + chunk);
    #});
    res.on "end", ->
      if clients[id]
        stats.clients--
        delete clients[id]
      stats.ended_req++

    res.on "error", ->
      if clients[id]
        stats.clients--
        delete clients[id]
      stats.errors_resp++


  req.on "error", ->
    stats.inproc--
    stats.errors_req++

  req.end()
http = require("http")
config =
  n: 0
  concurrency: 100
  host: "127.0.0.1"
  port: 8888
  controlPort: 8889

stats =
  clients: 0
  inproc: 0
  errors_req: 0
  errors_resp: 0
  ended_req: 0

clients = {}

# Controlling loop.
setInterval (->
  
  # Make connections if needed.
  makeRequest()  while config.n > stats.clients + stats.inproc and stats.inproc < config.concurrency
  
  # Abort connections if needed.
  if config.n < stats.clients
    keys = Object.keys(clients).slice(0, stats.clients - config.n)
    i = 0

    while i < keys.length
      clients[keys[i]].abort()
      stats.clients--
      delete clients[keys[i]]
      i++
), 100

# Output stats to console for debugging.
# With upstart job, it ends up in /var/log/upstart/client.log.
console.log "==== Client Started ===== Time: " + new Date().toISOString()
setInterval (->
  console.log JSON.stringify(stats)
), 1000

# Controlling server.

# Return stats on '/'

# Set params on '/set', preserving the type of param.

# Restart process on '/restart'
http.createServer((req, res) ->
  if req.method is "GET"
    url = require("url").parse(req.url, true)
    if url.pathname is "/"
      return res.end(JSON.stringify(stats) + "\n")
    else if url.pathname is "/set"
      for key of url.query
        config[key] = (if (typeof config[key] is "number") then +url.query[key] else url.query[key])
      return res.end(JSON.stringify(config) + "\n")
    else if url.pathname is "/restart"
      require("child_process").exec "sudo restart client", ->

      return res.end("OK\n")
  res.writeHead 404
  res.end()
).listen config.controlPort
