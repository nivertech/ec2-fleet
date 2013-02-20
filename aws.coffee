#!/usr/bin/env coffee

# Start equally in all regions.

# ====== Working with instances ===============================================
normalizeResponse = (obj, key) -> # Handles quirks of xml-to-js transformation ('item', empty objects)
  if typeof obj is "object"
    keys = Object.keys(obj)
    if keys.length is 0
      # Heuristic to determine empty arrays from empty strings.
      return []  if key and (key.slice(-3) is "Set" or key.slice(-1) is "s")
      return ""
    if keys.length is 1 and keys[0] is "item"
      obj.item = [obj.item]  unless Array.isArray(obj.item)
      return normalizeResponse(obj.item)
    i = 0

    while i < keys.length
      obj[keys[i]] = normalizeResponse(obj[keys[i]], keys[i])
      i++
  obj

# We are interested in Ubuntu Server 12.04 LTS (64 bit, EBS)
# {<region>: <ec2 client>}
getClient = (region) ->
  region = region or config.regions[0] or "us-east-1"
  unless clients[region]
    client = clients[region] = aws2js.load("ec2")
    client.region = region
    throw new Error("Unknown AWS region: " + region + ". Must be one of: " + Object.keys(regionInstances))  unless region of regionInstances
    client.setRegion region
    throw new Error("Please provide AWS Access Keys in 'aws-config.json' file.")  if typeof config.accessKeyId isnt "string" or config.accessKeyId.length isnt 20 or typeof config.accessKeySecret isnt "string" or config.accessKeySecret.length isnt 40
    client.setCredentials config.accessKeyId, config.accessKeySecret
  clients[region]
startInstance = (client) ->
  
  # Prepare userdata and do a basic templating (replace <%=filename.ext%> to contents of filename.ext).
  userdata = fs.readFileSync(config.userDataFile, "utf8").replace(/<%=(.*)%>/g, (_, name) ->
    fs.readFileSync name, "utf8"
  )
  
  # We use Cloud Init, see https://help.ubuntu.com/community/CloudInit
  params =
    InstanceType: (config.instanceType or "t1.micro")
    ImageId: regionInstances[client.region]
    MinCount: 1
    MaxCount: 1
    UserData: new Buffer(userdata).toString("base64")

  
  # To gain ssh access to instances, you should either upload a key to 
  # all given EC2 regions and use it here, or use Cloud Init to write them manually.
  params.KeyName = config.keyName  if config.keyName
  
  # http://docs.amazonwebservices.com/AWSEC2/latest/APIReference/ApiReference-query-RunInstances.html
  client.request "RunInstances", params, (err, resp) ->
    return console.error("RunInstances error: ", JSON.stringify(err))  if err
    resp = normalizeResponse(resp)
    instanceId = resp.instancesSet[0].instanceId
    params = "ResourceId.1": instanceId
    keys = Object.keys(config.instanceTags)
    i = 0

    while i < keys.length
      params["Tag." + (i + 1) + ".Key"] = keys[i]
      params["Tag." + (i + 1) + ".Value"] = config.instanceTags[keys[i]]
      i++
    if keys.length > 0
      client.request "CreateTags", params, (err, resp) ->
        return console.error("CreateTags error: ", JSON.stringify(err))  if err
        console.log "Instance " + instanceId + " started in region " + client.region

    else
      console.log "Instance " + instanceId + " started in region " + client.region

stopInstances = (client, instanceIdArray) ->
  return  if instanceIdArray.length is 0 # Nothing to do.
  params = {}
  i = 0

  while i < instanceIdArray.length
    params["InstanceId." + (i + 1)] = instanceIdArray[i]
    i++
  client.request "TerminateInstances", params, (err, resp) ->
    return console.error("TerminateInstances error: ", JSON.stringify(err))  if err
    console.log "Instances " + instanceIdArray.join(", ") + " terminated in region " + client.region

getInstances = (client, callback) ->
  client.request "DescribeInstances", (err, resp) ->
    return callback(err)  if err
    resp = normalizeResponse(resp)
    instances = []
    resp.reservationSet.forEach (reservation) ->
      reservation.instancesSet.forEach (instance) ->
        
        # Check instance is in good state.
        # Possible instance states: pending | running | shutting-down | terminated | stopping | stopped
        goodStates = ["pending", "running", "shutting-down"]
        return  if goodStates.indexOf(instance.instanceState.name) < 0
        
        # Check instance tags. All tags given in config must be the same.
        if config.instanceTags
          tags = {}
          instance.tagSet.forEach (item) ->
            tags[item.key] = item.value

          for key of config.instanceTags
            return  if config.instanceTags[key] isnt tags[key]
        
        # All checks successful, add instance to the resulting array.
        instances.push instance


    callback null, instances

pad = (str, width) ->
  str = " " + str  while str.length < width
  str
# Array of arrays of instances
# instance-id -> {lastUpdateTime: .., updateReq: ..., updateRes: {}}
printStatus = ->
  process.stdout.write "\u001bc" # Clear screen.
  status.forEach (regionInstances, i) ->
    console.log statusRegions[i] + ": "
    regionInstances.forEach (inst) ->
      message = "Unknown"
      u = updaters[inst.instanceId]
      if u
        t1 = (if (u.lastUpdateTime > u.lastReqTime) then ((u.lastUpdateTime - u.lastReqTime) / 100).toFixed(0) else "  ")
        t2 = ((Date.now() - u.lastReqTime) / 100).toFixed(0)
        message = "(" + pad(t1, 2) + "/" + pad(t2, 2) + ") " + JSON.stringify(u.updateRes).replace(/[{}"]/g, "")
        message += " [" + u.updateErr.code + "]"  if u.updateErr
      console.log "  " + inst.instanceId + "[" + inst.instanceState.name + "]: " + message
      unless u
        updaters[inst.instanceId] = u =
          lastUpdateTime: Date.now()
          lastReqTime: 0
          updateRes: {}
      rt = Date.now() - u.lastReqTime
      if rt > 2000
        
        #if (u.updateReq) {u.updateReq.abort(); delete u.updateReq;}
        unless inst.dnsName is ""
          u.lastReqTime = Date.now()
          req = http.request(
            host: inst.dnsName
            port: 8889
          )
          req.setHeader "Connection", "keep-alive"
          u.updateReq = req
          req.on "response", (res) ->
            text = ""
            res.setEncoding "utf8"
            res.on "data", (data) ->
              text = text + data

            res.on "end", ->
              u.lastUpdateTime = Date.now()
              u.updateRes = JSON.parse(text)
              delete u.updateErr

              delete u.updateReq


          req.on "error", (err) ->
            u.updateErr = err
            delete u.updateReq

          req.end()


updateInstances = (regions) ->
  async.map regions.map(getClient), getInstances, (err, res) ->
    return console.error("DescribeInstances error: " + JSON.stringify(err))  if err
    status = res
    statusRegions = regions
    updateInstances regions

sendParam = (client, inst, param, val) ->
  return console.error("Instance " + inst.instanceId + " has no dnsName.")  unless inst.dnsName
  p = {}
  p[param] = val
  query = require("querystring").stringify(p)
  path = (if (query is "restart=1") then "/restart" else ("/set?" + query))
  req = http.request(
    host: inst.dnsName
    port: config.controlPort
    path: path
  )
  req.on "response", (res) ->
    return console.error("Instance " + inst.instanceId + " status code = " + res.statusCode)  if res.statusCode isnt 200
    text = ""
    res.setEncoding "utf8"
    res.on "data", (data) ->
      text += data

    res.on "end", ->
      console.log "Instance " + inst.instanceId + " OK: " + text


  req.on "error", (err) ->
    console.error "Instance " + inst.instanceId + " error:" + err

  req.end()

#===============================================================================

fs = require("fs")
http = require("http")
aws2js = require("aws2js")
program = require("commander")
async = require("async")
config = require("./aws-config.json")

command_given = false
program.version "0.1.0"
program.command("start [num] [region]").description("Add <num> AWS instances. Default = 1.").action (num, region) ->
  command_given = true
  nInstances = +(num or 1)
  regions = (if region then [region] else config.regions)
  i = 0

  while i < nInstances
    startInstance getClient(regions[i % regions.length])
    i++

program.command("stop [num] [region]").description("Remove <num> AWS instances. Default = 1. Accepts 'all'.").action (num, region) ->
  command_given = true
  nInstances = (if (num is "all") then 10000 else +(num or 1))
  regions = (if region then [region] else config.regions)
  async.map regions.map(getClient), getInstances, (err, res) ->
    instanceCount = res.map((r) ->
      r.length
    ).reduce((a, b) ->
      a + b
    , 0)
    nInstances = Math.min(nInstances, instanceCount)
    regionId = -1
    instancesToTerminate = regions.map(->
      []
    )
    i = 0

    while i < nInstances
      regionId = (regionId + 1) % regions.length
      regionId = (regionId + 1) % regions.length  while res[regionId].length is 0
      instancesToTerminate[regionId].push res[regionId].shift().instanceId
      i++
    i = 0

    while i < regions.length
      stopInstances getClient(regions[i]), instancesToTerminate[i]
      i++


program.command("status [region]").description("Top-like automatically updating status of instances in all regions.").action (region) ->
  command_given = true
  regions = (if region then [region] else config.regions)
  updateInstances regions
  setInterval printStatus, 500

program.command("set <param> <value>").description("Set a parameter to given value in all current instances.").action (param, val) ->
  command_given = true
  regions = config.regions
  regions.map(getClient).forEach (client) ->
    getInstances client, (err, instances) ->
      i = 0

      while i < instances.length
        sendParam client, instances[i], param, val
        i++



regionInstances =
  "ap-northeast-1": "ami-c641f2c7"
  "ap-southeast-1": "ami-acf6b0fe"
  "eu-west-1": "ami-ab9491df"
  "sa-east-1": "ami-5c03dd41"
  "us-east-1": "ami-82fa58eb"
  "us-west-1": "ami-5965401c"
  "us-west-2": "ami-4438b474"

clients = {}
status = []
statusRegions = []
updaters = {}

# == Process command line arguments ===========================================
program.parse process.argv
program.parse process.argv.slice(0, 2).concat(["-h"])  unless command_given # Print help.
