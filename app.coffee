hapi = new (require('hapi')).Server()
https = require 'https'
neo = require('neo4j').GraphDatabase process.env.GRAPHSTORY_URL

dateFormat = new Intl.DateTimeFormat 'en-GB'

hapi.connection port: process.env.port || 3000

authenticateAdmin = (userID, cb) ->
  query2 = "token=#{process.env.SLACK_API_TOKEN}&user=#{req.payload.user_id}"
  valid = https.request method: 'POST', port: 80, hostname: 'slack.com', path: '/api/users.info',
                        headers: {'Content-Type': 'application/x-www-form-urlencoded', 'Content-Length': query2.length}, (res) ->
    res.setEncoding 'utf-8'
    res.on 'data', (r2) ->
      r2 = JSON.parse r2
      if not r2.ok
        cb error: r2.error

      else if r2.user.is_admin
        cb admin: true
      else
        cb admin: false

  valid.write query2
  valid.end()

hapi.route
  method: 'POST'
  path: '/slack/points'
  handler: (req, reply) ->
    console.log "POINTS received #{JSON.stringify req.payload}"

    if req.payload.token is process.env.SLACK_HOOK_TOKEN
      # give name... score for activity
      if query = /^give ([a-z][a-z ]+(?:, ?[a-z][a-z ]+)*) (\d+) for (\w[\w ]+)/i.exec req.payload.text
        date = dateFormat.format new Date()

        errors = []
        result = []
        people = query[1].split(',')
        await
          for person, i in people
            neo.query '''
                      MERGE (id:UniqueId)
                      ON CREATE SET id.next = 1
                      ON MATCH SET id.next = id.next + 1
                      WITH id.next AS uid
                      MATCH (p:Person {name: { person }, inactive: false})
                      WITH uid, p, count(*) AS ch
                      WHERE ch = 1
                      CREATE (p)-[:Entry {uid: uid,
                                          score: { score },
                                          author: { author }}]-(:Activity {activity: { activity },
                                                                           date: { date }})
                      RETURN ch
                      ''', 
                      activity: query[3].toLowerCase(),
                      author: req.payload.user_id,
                      date: date
                      person: person.trim().toLowerCase(),
                      score: query[2],
                      defer errors[i], result[i]

        builder = "<#{req.payload.user_id}>, I've added #{activity} for you. "
        builder += "**#{result.reduce((p, c, i, a) -> p + c.ch)}** records added"
        
        erroneous = errors.reduce ((p, c, i, a) -> if c then (if p is '' then query[i*2] else p + ", #{query[i*2]}")), ''
        if erroneous then builder += " although there were errors adding scores for **#{erroneous}**"

        missing = result.reduce ((p, c, i, a) -> if not c.ch then (if p is '' then query[i*2] else p + ", #{query[i*2]}")), ''
        if missing then builder += ", but I don't know who **#{missing}** are"

        console.log "POINTS::give1 REPLYING #{builder + '.'}"
        reply({text: builder + '.'}).code(200)

      # give name, score ... for activity
      else if query = /^give ([a-z][a-z ]+) (\d+)(?:,( ?[a-z][a-z ]+) (\d+))* for (\w[\w ]+)/i.exec req.payload.text
        date = dateFormat.format new Date()

        errors = []
        result = []
        query.unshift() # to remove the full query[0]
        activity = query.pop().toLowerCase()

        await
          for person, i in query by 2
            neo.query '''
                      MERGE (id:UniqueId)
                      ON CREATE SET id.next = 1
                      ON MATCH SET id.next = id.next + 1
                      WITH id.next AS uid
                      MATCH (p:Person {name: { person }, inactive: false})
                      WITH uid, p, count(*) AS ch
                      WHERE ch = 1
                      CREATE (p)-[:Entry {uid: uid,
                                          score: { score },
                                          author: { author }}]-(:Activity {activity: { activity },
                                                                           date: { date }})
                      RETURN ch
                      ''', 
                      activity: activity,
                      author: req.payload.user_id,
                      date: date
                      person: person.toLowerCase(),
                      score: query[i+1],
                      defer errors[i/2], result[i/2]

        builder = "<#{req.payload.user_id}>, I've added #{activity} for you. "
        builder += "**#{result.reduce((p, c, i, a) -> p + c.ch)}** records added"
        
        erroneous = errors.reduce ((p, c, i, a) -> if c then (if p is '' then query[i*2] else p + ", #{query[i*2]}")), ''
        if erroneous then builder += " although there were errors adding scores for **#{erroneous}**"

        missing = result.reduce ((p, c, i, a) -> if not c.ch then (if p is '' then query[i*2] else p + ", #{query[i*2]}")), ''
        if missing then builder += ", but I don't know who **#{missing}** are"

        console.log "POINTS::give2 REPLYING #{builder + '.'}"
        reply({text: builder + '.'}).code(200)

      # leaderboard [for group]
      else if 0 is req.payload.text.indexOf 'leaderboard'
        if group = /^leaderboard for ([a-z][a-z ]+)/i.exec req.payload.text
          await neo.query '''
                          MATCH (g:Group {name: { group }})--(p:Person)
                          OPTIONAL MATCH (p:Person)-[e:Entry]-(:Activity)
                          WITH p.name AS person, p.inactive AS inactive, g.name AS group, sum(e.score) AS score
                          RETURN person, inactive, group, score
                          ORDER BY score DESC
                          ''',
                          group: group[1].toLowerCase(),
                          defer error, result
        else
          await neo.query '''
                          MATCH (g:Group)--(p:Person)
                          OPTIONAL MATCH (p:Person)-[e:Entry]-(:Activity)
                          LIMIT 10
                          WITH p.name AS person, p.inactive AS inactive, g.name AS group, sum(e.score) AS score
                          RETURN person, inactive, group, score
                          ORDER BY score DESC
                          ''',
                          defer error, result

        if error
          builder = "<#{req.payload.user_id}>, there was an error getting a leaderboard for you: #{error}"
        else
          builder = "<#{req.payload.user_id}>, I've fetched the leaderboard #{('for ' + group[0]) if group}> for you: \n" +
                    result.reduce ((p, c, i, a) -> if p is ''
                                                     "**c.person** (#{(c.group + ', ') if c.group}#{c.score})"
                                                   else
                                                     ', ' + "**c.person** (#{'left, ' if c.inactive}#{(c.group + ', ') if c.group}#{c.score})"), ''

        console.log "POINTS::leaderboard REPLYING #{builder + '.'}"
        reply({text: builder + '.'}).code(200)

      # list for name|group|activity|author|date...
      else if query = /^list for ([a-z][a-z ]+)|([0-3][0-9]-[0-1][0-9]-20[0-9][0-9])/i.exec req.payload.text
        if query[1]
          await neo.query '''
                          MATCH (g:Group {name: { name }})--(p:Person {inactive: false})--[e:Entry]--(a:Activity)
                          RETURN p.name AS person, g.name AS group, e.score AS score, e.assigned AS assigned,
                                 e.verification AS verify, e.author AS author, a.activity AS activity, a.date AS date
                          UNION
                          MATCH (g:Group)--(p:Person {name: { name }, inactive: false})--[e:Entry]--(a:Activity)
                          RETURN p.name AS person, g.name AS group, e.score AS score, e.assigned AS assigned,
                                 e.verification AS verify, e.author AS author, a.activity AS activity, a.date AS date
                          UNION
                          MATCH (g:Group)--(p:Person {inactive: false})--[e:Entry {author: { name }}]--(a:Activity)
                          RETURN p.name AS person, g.name AS group, e.score AS score, e.assigned AS assigned,
                                 e.verification AS verify, e.author AS author, a.activity AS activity, a.date AS date
                          UNION
                          MATCH (g:Group)--(p:Person {inactive: false})--[e:Entry]--(a:Activity {activity: { name }})
                          RETURN p.name AS person, g.name AS group, e.score AS score, e.assigned AS assigned,
                                 e.verification AS verify, e.author AS author, a.activity AS activity, a.date AS date
                          ''',
                          name: query[1].toLowerCase(),
                          defer error, result
        else if query[2]
          await neo.query '''
                          MATCH (g:Group)--(p:Person {inactive: false})--[e:Entry]--(a:Activity {date: { date }})
                          RETURN p.name AS person, g.name AS group, e.score AS score, e.assigned AS assigned,
                                 e.verification AS verify, e.author AS author, a.activity AS activity, a.date AS date
                          ''',
                          date: query[2],
                          defer error, result

        if error
          builder = "<#{req.payload.user_id}>, there was an error getting a list for #{query[1]} for you: #{error}"
        else
          builder = "<#{req.payload.user_id}>, I've fetched a list for #{query[1]} for you: " +
                    result.reduce ((p, c, i, a) -> "\n**#{c.person}** (#{c.group}) did **#{c.activity}** for **#{c.score}** on #{c.date} (#{c.author}#{(' & ' + verify) if verify}#{(', needs verification from ' + assigned) if assigned})"), ''

        console.log "POINTS::list REPLYING #{builder + '.'}"
        reply({text: builder + '.'}).code(200)

      # reset
      else if query = 'reset'
        await authenticateAdmin req.payload.user_id, defer auth

        if auth.error
          builder = "<#{req.payload.user_id}>, there was an error authenticating you: #{auth.error}."
        else if auth.admin
          await neo.query '''
                          MATCH ()-[e:Entry]-(a:Activity)
                          UNION
                          MATCH (p:Person {inactive: true})
                          DELETE p, e, a
                          ''',
                          defer error, result

          if error
            builder = "<#{req.payload.user_id}>, there was an error resetting for you: #{error}."
          else
            builder = "<#{req.payload.user_id}>, everything has been reset."
        else
            builder = "<#{req.payload.user_id}>, it looks like you can't instigate a reset."

        console.log "POINTS::reset REPLYING #{builder}"
        reply({text: builder}).code(200)
      else
        console.log "POINTS::null NO REPLY"
    else
      console.log "POINTS::null BAD_TOKEN"

hapi.route
  method: 'POST',
  path: '/slack/whois',
  handler: (req, reply) ->
    console.log "WHOIS received #{JSON.stringify req.payload}"

    if req.payload.token is process.env.SLACK_HOOK_TOKEN
      # add name... to group
      if query = /^add ([a-z][a-z ]+(?:, ?[a-z][a-z ]+)*) to ([a-z][a-z]+)/i.exec req.payload.text
        await authenticateAdmin req.payload.user_id, defer auth

        if auth.error
          builder = "<#{req.payload.user_id}>, there was an error authenticating you: #{auth.error}"
        else if auth.admin
          people = query[1].split ','
          group = query[2].toLowerCase()
          await
            for person, i in people
              neo.query '''
                        CREATE (g:Group {name: { group }})--(p:Person {name: { person }, inactive: false})
                        RETURN p
                        ''',
                        group: group,
                        person: person.trim().toLowerCase(),
                        defer errors[i], result[i]

          builder = "<#{req.payload.user_id}>, I've added people to #{group} for you. "
          builder += "**#{result.reduce((p, c, i, a) -> p + (if c.p then 1 else 0))}** records added"
          
          erroneous = errors.reduce ((p, c, i, a) -> if c then (if p is '' then people[i] else p + ", #{people[i]}")), ''
          if erroneous then builder += " although there were errors adding **#{erroneous}**"
        else
          builder = "<#{req.payload.user_id}>, it looks like you can't instigate an addition"

        console.log "WHOIS::add REPLYING #{builder + '.'}"
        reply({text: builder + '.'}).code(200)

      # move name... to group
      else if query = /^move ([a-z][a-z ]+(?:, ?[a-z][a-z ]+)*) to ([a-z][a-z]+)/i.exec req.payload.text
        await authenticateAdmin req.payload.user_id, defer auth

        if auth.error
          builder = "<#{req.payload.user_id}>, there was an error authenticating you: #{auth.error}"
        else if auth.admin
          people = query[1].split ','
          group = query[2].toLowerCase()
          await
            for person, i in people
              neo.query '''
                        MATCH (:Group)-[r]-(p:Person {name: { person }, inactive: false})
                        DELETE r
                        CREATE (:Group {name: { group }})--(p)
                        RETURN p
                        ''',
                        group: group,
                        person: person.trim().toLowerCase(),
                        defer errors[i], result[i]

          builder = "<#{req.payload.user_id}>, I've moved people to #{group} for you. "
          builder += "**#{result.reduce((p, c, i, a) -> p + (if c.p then 1 else 0))}** records changed"
          
          erroneous = errors.reduce ((p, c, i, a) -> if c then (if p is '' then people[i] else p + ", #{people[i]}")), ''
          if erroneous then builder += " although there were errors moving **#{erroneous}**"

          missing = result.reduce ((p, c, i, a) -> if not c.p then (if p is '' then people[i] else p + ", #{people[i]}")), ''
          if missing then builder += ", but I don't know who **#{missing}** are"
        else
          builder = "<#{req.payload.user_id}>, it looks like you can't instigate a move"

        console.log "WHOIS::move REPLYING #{builder + '.'}"
        reply({text: builder + '.'}).code(200)

      # name... left
      else if query = /^([a-z][a-z ]+(?:, ?[a-z][a-z ]+)*) left/i.exec req.payload.text
        await authenticateAdmin req.payload.user_id, defer auth

        if auth.error
          builder = "<#{req.payload.user_id}>, there was an error authenticating you: #{auth.error}"
        else if auth.admin
          people = query[1].split ','
          await 
            for person, i in people
              neo.query '''
                        MATCH (p:Person {name: { person }})
                        WITH 
                        WHERE ch = 1
                        SET ch.inactive = true
                        RETURN ch
                        ''',
                        person: person.trim().toLowerCase(),
                        defer errors[i], result[i]

          builder = "<#{req.payload.user_id}>, I've completed that update for you. "
          builder += "**#{result.reduce((p, c, i, a) -> p + c.ch)}** records changed"
            
          erroneous = errors.reduce ((p, c, i, a) -> if c then (if p is '' then people[i] else p + ", #{people[i]}")), ''
          if erroneous then builder += " although there were errors moving **#{erroneous}**"

          missing = result.reduce ((p, c, i, a) -> if not c.ch then (if p is '' then people[i] else p + ", #{people[i]}")), ''
          if missing then builder += ", but I don't know who **#{missing}** are"

        else
          builder = "<#{req.payload.user_id}>, it looks like you can't instigate an update"

        console.log "WHOIS::left REPLYING #{builder + '.'}"
        reply({text: builder + '.'}).code(200)

      # who is in group
      else if query = /^who is in ([a-z][a-z]+)/i.exec(req.payload.text) or query = /list ([a-z][a-z]+)/i.exec req.payload.text
        await neo.query '''
                        MATCH (g:Group {name: { group }})--(p:Person)
                        RETURN p
                        ''',
                        group: query[1].trim().toLowerCase(),
                        defer error, results
        if error
          builder = "<#{req.payload.user_id}>, there was an error fetching #{query[1].trim().toLowerCase()} for you: #{error}."
        else
          people = results.reduce ((p, c, i, a) -> if p is '' then "**#{c}**" else if i is a.length - 1 then "#{p} and **#{c}**" else "#{p}, **#{c}**"), ''
          builder = "<#{req.payload.user_id}>, #{people} are in #{query[1].trim().toLowerCase()}."

        console.log "WHOIS::in REPLYING #{builder}"
        reply({text: builder}).code(200)

      # who is name
      else if query = /^who is ([a-z][a-z ]+)/i.exec req.payload.text
        await neo.query '''
                        MATCH (g:Group)--(p:Person {name: { name }})
                        RETURN p, g.name AS g2
                        ''',
                        name: query[1].trim().toLowerCase(),
                        defer error, result

        if error
          builder = "<#{req.payload.user_id}>, there was an error fetching #{query[1].trim().toLowerCase()} for you: #{error}."
        else if result.g2
          builder = "<#{req.payload.user_id}>, **#{result.p.name}** #{if result.p.inactive then 'was' else 'is'} in **#{result.g2}**"
        else
          builder = "<#{req.payload.user_id}>, **#{query[1].trim().toLowerCase()}** was not found"

        console.log "WHOIS::whois REPLYING #{builder}"
        reply({text: builder}).code(200)
      else
        console.log "WHOIS::null NO REPLY"
    else
      console.log "WHOIS::null BAD_TOKEN"

hapi.route
  method: 'POST',
  path: '/slack/reportbook',
  handler: (req, reply) ->
    console.log "REPORTBOOK received #{JSON.stringify req.payload}"

    if req.payload.token is process.env.SLACK_HOOK_TOKEN
      # list assigned
      if req.payload.text.toLowerCase() is 'list assigned'
        await neo.query '''
                        MATCH (g:Group)--(p:Person)-[e:Entry:ReportBookEntry {assigned: { u }}]-(a:Activity:ReportBook)
                        RETURN p.name AS person, g.name AS group, e.uid AS uid, e.assigned AS assigned,
                               e.verification AS verify, e.author AS author, a.activity AS activity, a.date AS date
                        ''',
                        u: req.payload.user_id,
                        defer error, results

        if error
          builder = "<#{req.payload.user_id}>, there was an error fetching your assignments: #{error}."
        else if results.length > 0
          builder = "<#{req.payload.user_id}>, here's your assignments: " +
                    result.reduce ((p, c, i, a) -> "\n**#{c.uid}**:\u2002**#{c.person}** (#{c.group}) did **#{c.activity}** on #{c.date} (#{c.author})"), ''
        else
          builder = "<#{req.payload.user_id}>, you have no assignments."

        console.log "REPORTBOOK::assigned REPLYING #{builder}"
        reply({text: builder}).code(200)

      # list for person|group
      else if query = /^list for ([a-z][a-z ]+)/i.exec req.payload.text
        await neo.query '''
                        MATCH (g:Group)--(p:Person {name: { name }})-[e:Entry:ReportBookEntry]-(a:Activity:ReportBook)
                        RETURN p.name AS person, g.name AS group, e.uid AS uid, e.assigned AS assigned,
                               e.verification AS verify, e.author AS author, a.activity AS activity, a.date AS date
                        UNION
                        MATCH (g:Group {name: { name }})--(p:Person)-[e:Entry:ReportBookEntry]-(a:Activity:ReportBook)
                        RETURN p.name AS person, g.name AS group, e.uid AS uid, e.assigned AS assigned,
                               e.verification AS verify, e.author AS author, a.activity AS activity, a.date AS date
                        ''',
                        name: query[1].trim().toLowerCase(),
                        defer error, results

        if error
          builder = "<#{req.payload.user_id}>, there was an error fetching reports about #{query[1].trim().toLowerCase()}: #{error}"
        else if results.length > 0
          builder = "<#{req.payload.user_id}>, here's the reports about #{query[1].trim().toLowerCase()}: " +
                    result.reduce ((p, c, i, a) -> "\n**#{c.uid}**:\u2002**#{c.person}** (#{c.group}) did **#{c.activity}** on #{c.date} (#{c.author})"), ''
        else
          builder = "<#{req.payload.user_id}>, there are no reports for #{query[1].trim().toLowerCase()}"

        console.log "REPORTBOOK::list REPLYING #{builder + '.'}"
        reply({text: builder + '.'}).code(200)

      # authorise id
      else if query = /^authorise ([0-9]+)/i.exec req.payload.text
        await authenticateAdmin req.payload.user_id, defer auth

        if auth.error
          builder = "<#{req.payload.user_id}>, there was an error authenticating you: #{auth.error}"
        else if auth.admin
          await neo.query '''
                          MATCH (p:Person)-[e:Entry:ReportBookEntry {uid: { uid }}]-(a:Activity)
                          WHERE HAS (e.assigned)
                          SET e.verification = { u }
                          REMOVE e.assigned
                          RETURN e.uid AS uid2
                          ''',
                          u: req.payload.user_id,
                          uid: query[1],
                          defer error, result

          if error
            builder = "<#{req.payload.user_id}>, there was an error verifying report #{query[1]}: #{error}."
          else if result.uid2
            builder = "<#{req.payload.user_id}>, you have verified report #{result.uid2}."
          else
            builder = "<#{req.payload.user_id}>, report #{query[1]} either does not require verification, or could not be found."
        
        else
          builder = "<#{req.payload.user_id}>, it looks like you can't verify reports."

        console.log "REPORTBOOK::auth REPLYING #{builder}"
        reply({text: builder}).code(200)

      else if query = /^delete ([0-9]+)/i.exec req.payload.text
        await authenticateAdmin req.payload.user_id, defer auth

        if auth.error
          builder = "<#{req.payload.user_id}>, there was an error authenticating you: #{auth.error}"
        else if auth.admin
          await neo.query '''
                          MATCH ()-[e:Entry:ReportBookEntry {uid: { uid }}]-()
                          DELETE e

                          MATCH (a:Activity)
                          WHERE NOT (a)-[:Entry]-()
                          DELETE a
                          ''',
                          u: req.payload.user_id,
                          uid: query[1],
                          defer error, result

          if error
            builder = "<#{req.payload.user_id}>, there was an error deleting report #{query[1]}: #{error}."
          else if result.uid2
            builder = "<#{req.payload.user_id}>, you have deleted report #{result.uid2}."
          else
            builder = "<#{req.payload.user_id}>, report #{query[1]} could not be found."
        
        else
          builder = "<#{req.payload.user_id}>, it looks like you can't delete reports."

        console.log "REPORTBOOK::delete REPLYING #{builder}"
        reply({text: builder}).code(200)

      # snco, name did action
      else if query = /^@([0-9a-z][0-9a-z.-_]+), ([a-z][a-z ]+) did (\w[\w ]+)/i.exec req.payload.text
        date = dateFormat.format new Date()

        snco = query[0]
        person = query[1]
        activity = query[2]

        await neo.query '''
                        MERGE (id:UniqueId)
                        ON CREATE SET id.next = 1
                        ON MATCH SET id.next = id.next + 1
                        WITH id.next AS uid
                        MATCH (p:Person {name: { person }, inactive: false})
                        WITH uid, p, count(*) AS ch
                        WHERE ch = 1
                        CREATE (p)-[:Entry:ReportBookEntry {uid: uid,
                                                            score: -50,
                                                            author: { author },
                                                            assigned: { snco }}]-(:Activity:ReportBook {activity: { activity },
                                                                                                       date: { date }})
                        RETURN uid
                        ''',
                        person: person,
                        snco: snco,
                        activity: activity,
                        date: date,
                        author: req.payload.user_id,
                        defer error, result

        if error
          builder = "<#{req.payload.user_id}>, there was an error creating your report for #{person}: #{error}."
        else if result.uid
          builder = "<#{req.payload.user_id}>, you have created report #{result.uid2} for #{person}."
        else
          builder = "<#{req.payload.user_id}>, your report for #{person} does not appear to have been created."

        console.log "REPORTBOOK::do REPLYING #{builder}"
        reply({text: builder}).code(200)
      else
        console.log "REPORTBOOK::null NO REPLY"
    else
      console.log "REPORTBOOK::null BAD_TOKEN"

server.views({
    engines: {
        html: require('handlebars')
    },
    relativeTo: __dirname,
    path: './views',
    layoutPath: './views/layout',
    helpersPath: './views/helpers'
});

hapi.route
  method: 'GET',
  path: '/',
  handler: (req, reply) ->
    await neo.query '''
                    MATCH (g:Group)
                          OPTIONAL MATCH (g:Group)--(p:Person)-[e:Entry]-(:Activity)
                          LIMIT 10
                          WITH g.name AS group, sum(e.score) AS score
                          RETURN group, score
                          ORDER BY score DESC
                    ''',
                    defer error, result
    if result
      for r, i in result
        r2 = (Math.random() * 96 + 128).toString 16
        r.color = '#' + r2 + r2 + r2
    reply(error: error?, groups: result)

hapi.start ->
  console.log "SUPERNCO::start"
