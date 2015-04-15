#!/usr/bin/env ruby

require 'net/https'
require 'multi_json'
require 'yaml'
require 'time'

class Numeric
  def duration
    secs  = self.to_int
    mins  = secs / 60
    hours = mins / 60
    days  = hours / 24

    if days > 0
      "#{days} days and #{hours % 24} hours"
    elsif hours > 0
      "#{hours} hours and #{mins % 60} minutes"
    elsif mins > 0
      "#{mins} minutes and #{secs % 60} seconds"
    elsif secs >= 0
      "#{secs} seconds"
    end
  end
end

class CycleTimeForAcceptedStories
  # set environment variables TOKEN and PROJECT_ID to appropriate values for your project.
  @@tracker_host = ENV['TRACKER_HOST'] ||
    # 'http://localhost:3000' ||  # comment this out to default to prod
    'https://www.pivotaltracker.com'
  @@token = ENV['TOKEN'] || 'TestToken'
  @@project_id = ENV['PROJECT_ID'] || '101'

  def run
    stories = {}
    offset = 0
    limit = 100
    total = nil
    count = 0
    begin
      activity_with_envelope = get("projects/#{@@project_id}/activity", "offset=#{offset}&envelope=true")
      activity_items = activity_with_envelope['data']
      total = activity_with_envelope['pagination']['total']

      activity_items.each do |activity|
        count+=1
        puts "still working" if (count + 1) % 100 == 0  
        activity['changes'].each do |change_info|
          if is_state_change(change_info)
            story_id = change_info['id']
            stories[story_id] ||= {}
            stories[story_id]['id'] ||= story_id

            if change_info['new_values']['current_state'] == 'started'
              stories[story_id]['started_at'] = activity['occurred_at']
            elsif stories[story_id]['accepted_at'].nil? && change_info['new_values']['current_state'] == 'accepted'
              stories[story_id]['accepted_at'] = activity['occurred_at']
            else
              if change_info['new_values']['current_state'] == 'rejected'
                stories[story_id]['rejected_count'] ||= 0
                stories[story_id]['rejected_count'] += 1
              end
            end
          end
        end
      end

      offset += activity_with_envelope['pagination']['limit']
    end while total > offset

    # look up name and type for ech story
    stories.keys.each_slice(100) do |story_ids|
      search_results = get("projects/#{@@project_id}/search", "query=id:#{story_ids.join(',')}%20includedone:true")
      search_results['stories']['stories'].each do |story_hash|
        stories[story_hash['id']]['name'] = story_hash['name']
        # stories[story_hash['id']]['story_type'] = story_name['story_type']
      end
    end

    # drop stories where we can't compute cycle time (including all releases), and compute it for the ones left
    stories = stories.values.
        # select {|story_info| story_info['story_type'] != 'release'}.
        select {|story_info| story_info.has_key?('started_at') && story_info.has_key?('accepted_at') }.
        map do |story_info|
          story_info['cycle_time'] = Time.parse(story_info['accepted_at']) - Time.parse(story_info['started_at'])
          story_info
        end

    stories.
        sort_by { |story_info| story_info['cycle_time'] }.
        each do |story_info|
          name =  story_info['name'] || '*deleted*'
          puts sprintf("%12d:  cycle time was %-25.25s rejected count %-2d (%.40s#{name.length > 40 ? '...' : ''})", story_info['id'], story_info['cycle_time'].duration, story_info['rejected_count'].to_i, name)
        end
  end

  def is_state_change(change_info)
    change_info['kind'] == 'story' &&
      change_info['new_values'] &&
      change_info['new_values'].has_key?('current_state')
  end

  def get(url, query)
    request_header = {
      'X-TrackerToken' => @@token
    }

    uri_string = @@tracker_host + '/services/v5/' + url
#    puts uri_string    # print the URI of each GET request made
    resource_uri = URI.parse(uri_string)
    # resource_uri.query = URI.encode_www_form(query)
    http = Net::HTTP.new(resource_uri.host, resource_uri.port)
    http.use_ssl = @@tracker_host.start_with?('https')

    response = http.start do
      http.get(resource_uri.path + '?' + query, request_header)
    end

    MultiJson.load(response.body)
  end
end

CycleTimeForAcceptedStories.new.run
