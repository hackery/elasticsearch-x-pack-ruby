# An example of a complex configuration for Elasticsearch Watcher alerting and notification system.
#
# Execute this file from the root of the repository:
#
#     bundle exec ruby -I lib ./examples/watcher/error_500.rb
#
# The watch searches for `500` errors in a specific index on a periodic basis, and performs three
# actions when at least 3 errors have been received in the last 5 minutes:
#
# 1. indexes the error documents and aggregations returned from search,
# 2. sends a notification via e-mail, and
# 3. sends the data to a HTTP API.
#
# If you want to test sending the e-mail, you have to configure Watcher:
# <https://www.elastic.co/guide/en/x-pack/current/actions-email.html#configuring-email>
#
# You can run a simple Sinatra based web server to test the webhook action with this script:
#
#     $ ruby -r sinatra -r json -e 'post("/") { json = JSON.parse(request.body.read); puts %Q~Received #{json["watch_id"]} with payload: #{json["payload"]}~ }'
#

require 'elasticsearch'
require 'elasticsearch/xpack'

client = Elasticsearch::Client.new url: 'http://elastic:changeme@localhost:9260', log: true
client.transport.logger.formatter = proc do |severity, datetime, progname, msg| "\e[2m#{msg}\e[0m\n" end

# Delete the Watcher and test indices
#
['test_errors', 'alerts', '.watcher-history-*'].each do |index|
  client.indices.delete index: index, ignore: 404
end

# Print information about the Watcher plugin
#
puts "X-Pack #{client.xpack.info['build']['hash']}"

# Register a new watch
#
client.xpack.watcher.put_watch id: 'error_500', body: {
  # Label the watch
  #
  metadata: { tags: ['errors'] },

  # Run the watch every 10 seconds
  #
  trigger: { schedule: { interval: '10s' } },

  # Search for at least 3 documents matching the condition
  #
  condition: {  compare: { 'ctx.payload.hits.total' => { gt: 3 } } },

  # Throttle the watch execution for 30 seconds
  #
  throttle_period: '30s',

  # The search request to execute
  #
  input: {
    search: {
     request: {
       indices: ['test_errors'],
       body: {
         query: {
           bool: {
             must: [
              { match: { status: 500 } } ,
              { range: { timestamp: { from: '{{ctx.trigger.scheduled_time}}||-5m',
                                      to:   '{{ctx.trigger.triggered_time}}' } } }
             ]
           }
         },
         # Return hosts with most errors
         #
         aggregations: {
           hosts: { terms: { field: 'host' } }
         }
    }}}
  },

  # The actions to perform
  #
  actions: {
    send_email:    {
      transform: {
        # Transform the data for the template
        #
        script: {
          lang: 'painless',
          inline: "[ 'total': ctx.payload.hits.total, 'hosts': ctx.payload.aggregations.hosts.buckets.collect(bucket -> [ 'host': bucket.key, 'errors': bucket.doc_count ]), 'errors': ctx.payload.hits.hits.collect(d -> d._source) ]"
        }
      },
      email: { to:        'alerts@example.com',
               subject:   '[ALERT] {{ctx.watch_id}}',
               body:      <<-BODY.gsub(/^ {28}/, ''),
                            Received {{ctx.payload.total}} errors in the last 5 minutes.

                            Hosts:

                            {{#ctx.payload.hosts}}- {{host}} ({{errors}} errors)\n{{/ctx.payload.hosts}}

                            A file with complete data is attached to this message.\n
                          BODY
               attachments: { 'data.yml' => { data: { format: 'yaml' } } }
             }
    },

    index_payload: {
      # Transform the data to be stored
      #
      transform: {
        script: {
          lang: 'painless',
          inline: "[ 'watch_id': ctx.watch_id, 'payload': ctx.payload ]"
        }
      },
      index: { index: 'alerts', doc_type: 'alert' }
    },

    ping_webhook: {
      webhook: {
        method: 'post',
        url:    'http://localhost:4567',
        body:   %q|{"watch_id" : "{{ctx.watch_id}}", "payload" : "{{ctx.payload}}"}| }
    }
  }
}

# Create the index with example documents
#
client.indices.create index: 'test_errors', body: {
  mappings: {
    d: {
      properties: {
        host: { type: 'keyword' }
      }
    }
  }
}

# Index documents to trigger the watch
#
10.times do
  client.index index: 'test_errors', type: 'd',
               body: { timestamp: Time.now.utc.iso8601, status: "#{rand(4..5)}00", host: "10.0.0.#{rand(1..3)}" }
end

# Wait a bit...
#
print "Waiting 30 seconds..."
$i=0; while $i < 30 do
  sleep(1); print('.'); $i+=1
end; puts "\n"

# Display information about watch execution
#
client.search(index: '.watcher-history-*', q: 'watch_id:error_500', sort: 'trigger_event.triggered_time:asc')['hits']['hits'].each do |r|
  puts "#{r['_source']['watch_id']} #{r['_source']['state'].upcase} at #{r['_source']['result']['execution_time']}"
end

# Delete the watch
#
client.xpack.watcher.delete_watch id: 'error_500', master_timeout: '30s', force: true
