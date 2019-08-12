lib = File.expand_path('..', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require "reaper/version"
require 'socket'
require 'net/http'
require 'json'
require 'yaml'
require 'date'
require 'thor'
require 'terminal-table'
require 'ruby-progressbar'

module Reaper
  class Error < StandardError; end

  HARVEST_CLIENT_ID = 'c4CbEqRlWx1ziSITWP03BwjN'
  
  LOCAL_SERVER_PORT = 31390

  LOGIN_FILE_PATH = File.join(Dir.home, '.reaper')

  CONFIG_FILE_PATH = File.join(Dir.home, '.reaper_config')

  module_function

  def openWebpage(link)
    system("open", link)
  end

  def request(endpoint)
    uri = URI("https://api.harvestapp.com/v2/#{endpoint}")
    req = Net::HTTP::Get.new(uri)
    req['Accept'] = "application/json"
    req['Authorization'] = "Bearer #{$token}"
    req['Harvest-Account-ID'] = $acc_id

    begin
      res = Net::HTTP.start(uri.hostname, uri.port, :use_ssl => true) { |http|
        http.request(req)
      }
    rescue
      abort 'Cannot send request. Please check your network connection and try again.'
    end

    if res.kind_of? Net::HTTPSuccess
      JSON.parse res.body
    else
      nil
    end
  end
  
  def request_delete(endpoint)
    uri = URI("https://api.harvestapp.com/v2/#{endpoint}")
    req = Net::HTTP::Delete.new(uri)
    req['Accept'] = "application/json"
    req['Content-Type'] = "application/json"
    req['Authorization'] = "Bearer #{$token}"
    req['Harvest-Account-ID'] = $acc_id
    res = Net::HTTP.start(uri.hostname, uri.port, :use_ssl => true) { |http|
      http.request(req)
    }
    
    if res.kind_of? Net::HTTPSuccess
      JSON.parse res.body
    else
      nil
    end
  end
  
  def check_auth
    abort('Cannot find cached login info. Please run `reaper login` first.') unless restore_login_info
  end

  def restore_login_info
    return false if !File.exist? LOGIN_FILE_PATH
    login_data = YAML.load File.read(LOGIN_FILE_PATH)
    if login_data[:harvest_login]
      login = login_data[:harvest_login]
      token = login[:token]
      account_id = login[:account_id]
      user_id = login[:user_id]

      if token && !token.empty? && 
        account_id && account_id.is_a?(Integer) && 
        user_id && user_id.is_a?(Integer)
        $token = token
        $acc_id = account_id
        $user_id = user_id
        return true
      end
    end
    false
  end

  def load_config
    return false if !File.exist? CONFIG_FILE_PATH
    $config = YAML.load File.read(CONFIG_FILE_PATH)
    true
  end

  def show_config(config)
    puts "Reaper Configuration (version #{$config[:version]})"
    puts ''

    title = 'Global Settings'
    rows = []
    rows << ['Daily working hours negative offset', "#{$config[:daily_negative_offset]} hour(s)"]
    rows << ['Daily working hours positive offset', "#{$config[:daily_positive_offset]} hour(s)"]
    table = Terminal::Table.new :title => title, :rows => rows
    puts table

    puts ''

    title = 'Projects & Tasks Settings'
    headers = ['Project', 'Task', 'Percentage']

    rows = []
    $config[:tasks].each do |task|
      desc = "[#{task[:pcode]}] #{task[:pname]} (#{task[:client]})"
      rows << [desc.scan(/.{1,30}/).join("\n"), task[:tname], "#{(task[:percentage] * 100).round}%"]
    end

    table = Terminal::Table.new :title => title, :headings => headers, :rows => rows
    table.style = { :all_separators => true }
    puts table
  end

  def list_projects
    check_auth

    puts "Fetching your project list..."
    response = request 'users/me/project_assignments'
    puts "Cannot fetch your project list, please try agian later." unless response

    puts ''

    projects = response['project_assignments']
    # puts JSON.pretty_generate projects
    
    projects = projects.map do |p|
      pcode = p['project']['code']
      pname = p['project']['name']
      desc = "[#{pcode}] #{pname}"
      tasks = p['task_assignments']

      {
        :project_id => p['project']['id'],
        :project_name => pname,
        :project_code => pcode,
        :desc => desc,
        :client => p['client']['name'],
        :tasks => tasks.map do |t|
          {
            'tid' => t['task']['id'],
            'name' => t['task']['name']
          }
        end
      }
    end

    max_chars = (projects.max_by { |p| p[:desc].length })[:desc].length

    clients = projects.group_by { |p| p[:client] }.to_h.sort.to_h
    
    clients.each do |k, v|
      puts k
      puts '-' * max_chars
      v.sort_by! { |p| p[:project_code] }
      v.each do |p|
        puts p[:desc]
      end
      puts ''
    end

    puts "Total: #{projects.size}"

    clients
  end
      
  def start_config_server(global_settings, projects, added_tasks)
    puts 'Launching the configuration page in your browser...'
    
    server = TCPServer.new LOCAL_SERVER_PORT
    
    while session = server.accept
      request = session.gets

      next unless request
      
      if match = request.match(/\/reaper-config\s+/i)
        template_path = File.join root, 'assets/reaper_config_template.html'

        template = File.read(template_path)
          .sub('"{{RPR_GLOBAL_SETTINGS}}"', "JSON.parse('#{global_settings.to_json}')")
          .sub('"{{RPR_PROJECTS}}"', "JSON.parse('#{projects.to_json}')")
          .sub('"{{RPR_ADDED_TASKS}}"', "JSON.parse('#{added_tasks.to_json}')")
          
        session.print "HTTP/1.1 200\r\n"
        session.print "Content-Type: text/html\r\n"
        session.print "\r\n"
        session.print template
      elsif match = request.match(/\/submitTimeEntries\?([\S]+)\s+HTTP/i)
        params = match.captures.first
  
        raw_config = params.split('&').map { |arg| arg.split '=' }.to_h

        max_index = raw_config.keys.select { |e| e =~ /p\d+/ }
          .map { |e| e[1..-1].to_i }
          .max

        tasks = []
        (max_index + 1).times do |n|
          tasks << {
            :pid => raw_config["p#{n}"].to_i,
            :tid => raw_config["t#{n}"].to_i,
            :percentage => raw_config["pct#{n}"].to_i / 100.0
          }
        end

        tasks.each do |t|
          proj = projects.select { |p| p['pid'] == t[:pid] }.first
          if proj
            task = proj['tasks'].select { |it| it['tid'] == t[:tid] }.first
            t[:pcode] = proj['code']
            t[:pname] = proj['name']
            t[:client] = proj['client']
            t[:tname] = task['name']
          end

          abort 'Something went wrong' unless proj && task
        end
        
        $config = {
          :version => '0.1.0',
          :daily_negative_offset => raw_config['no'].to_i,
          :daily_positive_offset => raw_config['po'].to_i,
          :tasks => tasks
        }
        
        session.close
        break
      end
  
      session.close
    end
  end

  def root
    File.expand_path '../', File.dirname(__FILE__)
  end

  class Config < Thor
    desc "show", "Show your Reaper configuration"
    def show
      if Reaper.load_config
        Reaper.show_config $config
      else
        puts "No Reaper configuration is found"
      end
    end

    desc "update", "Set or update your Reaper configuration"
    def update
      projs = Reaper.list_projects
      abort unless projs
      
      if Reaper.load_config
        global_settings = {
          'noffset' => $config[:daily_negative_offset],
          'poffset' => $config[:daily_positive_offset]
        }
      else
        global_settings = {
          'noffset' => 0,
          'poffset' => 0
        }
      end
      
      projs_js = projs.values.flatten.map do |p|
        {
          'pid' => p[:project_id],
          'code' => p[:project_code],
          'name' => p[:project_name],
          'client' => p[:client],
          'tasks' => p[:tasks]
        }
      end

      added_tasks = []
      if $config
        added_tasks = $config[:tasks].map do |t|
          {
            'pid': t[:pid],
            'tid': t[:tid],
            'pct': t[:percentage],
          }
        end
      end
      
      puts ''
      Reaper.openWebpage("http://localhost:#{LOCAL_SERVER_PORT}/reaper-config");
      Reaper.start_config_server(global_settings, projs_js, added_tasks)
  
      if $config
        File.write(Reaper::CONFIG_FILE_PATH, $config.to_yaml)

        puts ''
        Reaper.show_config $config
        puts ''

        puts 'Reaper configuration successfully updated'
      end
    end

    desc "delete", "Delete your Reaper configuration"
    def delete
      if Reaper.load_config
        File.delete Reaper::CONFIG_FILE_PATH
        puts "Reaper configuration successfully deleted"
      else
        puts "No Reaper configuration is found"
      end
    end
  end

  class Main < Thor
  
    $token = nil
    $acc_id = nil
    $user_id = nil
    $config = nil
    
    desc "test", "test"
    def test
      a = {"no"=>"0", "po"=>"0", "p0"=>"20769370", "t0"=>"11683694", "pct0"=>"56", "p1"=>"20500923", "t1"=>"11728114", "pct1"=>"22", "p2"=>"20500918", "t2"=>"11728114", "pct2"=>"22"}
      puts a
  
      max_index = a.keys.select { |e| e =~ /p\d+/ }
        .map { |e| e[1..-1] }
        .max
  
      puts max_index
    end
    
    desc "login", "Login to your Harvest account to authorize Reaper"
    def login
      Reaper.openWebpage "https://id.getharvest.com/oauth2/authorize?client_id=#{HARVEST_CLIENT_ID}&response_type=token"
      
      start_login_server
  
      if $token
        me = Reaper.request 'users/me'
        $user_id = me['id']
        puts "Harvest user ID: #{$user_id}"
  
        login_data = { :harvest_login => 
          { :token => $token, :account_id => $acc_id, :user_id => $user_id } 
        }
        
        File.write(LOGIN_FILE_PATH, login_data.to_yaml)
      end
    end
  
    desc "account", "View your current Harvest login info"
    def account
      abort 'Harvest login info not found' unless File.exist? LOGIN_FILE_PATH
      
      login_data = YAML.load File.read(LOGIN_FILE_PATH)
      if login_data[:harvest_login]
        login = login_data[:harvest_login]
        token = login[:token]
        account_id = login[:account_id]
        user_id = login[:user_id]
  
        if token && !token.empty? && 
          account_id && account_id.is_a?(Integer) && 
          user_id && user_id.is_a?(Integer)
          puts """Your current Harvest login info:
    - Harvest token: #{token}
    - Harvest account ID: #{account_id}
    - Harvest user ID: #{user_id}"""
        end
      end
    end
  
    desc "me", "Show your Harvest profile"
    def me
      Reaper.check_auth

      puts "Fetching your profile, raw data will be directly shown here"
      puts ''
      puts JSON.pretty_generate Reaper.request 'users/me'
    end

    desc "config SUBCOMMAND", "Manage your Reaper configuration"
    subcommand "config", Config
    
    desc "projects", "Show your project list"
    def projects
      Reaper.list_projects
    end

    desc "show DATE/WEEK-ALIAS", "Show your recorded Harvest time entries in the given week"
    def show(date_str)
      mon, fri = get_week_range_from_date_str date_str
      
      Reaper.check_auth

      # both ruby and Harvest use ISO 8601 by default
      from = mon.to_s
      to = fri.to_s
      
      puts "Fetching your time entries from #{from} to #{to}"
      raw_entries = Reaper.request("time_entries?user_id=#{$user_id}&from=#{from}&to=#{to}")['time_entries']
  
      if raw_entries.empty?
        puts "Cannot find any time entries in the week of #{from}" 
        return []
      end
      
      entries = {}
      raw_entries.each do |e|
        date = Date.parse(e['spent_date'])
        tasks = entries[date] || []
        entries[date] = tasks if tasks.empty?
        tasks << {
          :id => e['id'],
          :created_at => DateTime.parse(e['created_at']),
          :project => e['project']['name'],
          :project_code => e['project']['code'],
          :task => e['task']['name'],
          :client => e['client']['name'],
          :hours => e['hours']
        }
      end
  
      # sort the entries hash to make sure:
      # - keys (spent date) are sorted by date
      # - values (daily entries) are sorted by entry created date
  
      entries = entries.sort.to_h
  
      entries.each do |k, v|
        v.sort_by! { |t| t[:created_at] }
      end
  
      print_time_entries mon, fri, entries

      return raw_entries, entries
    end
  
    desc "delete DATE/WEEK-ALIAS", "Delete all Harvest time entries in the given week"
    def delete(date_str)
      mon, fri = get_week_range_from_date_str date_str

      entries, _ = show date_str
      
      if !entries.empty?
        puts "Delete #{entries.size} entrires from #{mon} to #{fri}? (Y/n)"
        confirm = $stdin.gets.chomp
        abort 'Deletion cancelled' unless confirm == 'Y'
      end
      
      progressbar = ProgressBar.create(
        :title => 'Deleting', 
        :total => entries.size,
        :format => '%t %c/%C %B'
      )
      
      entries.each do |e|
        rsp = delete_entry e['id']
        if rsp 
          progressbar.increment
        else
          abort "Deleting request failed. Your deleting actions may not be completed. Please run `reaper show #{date_str}` to check."
        end
      end

      puts 'Deletion completed!'
    end
  
    desc "submit DATE/WEEK-ALIAS", "Submit Harvest time entries for you based on the configuration"
    option :excluded, :type => :string
    def submit(date_str)
      submit_time_entries date_str, options[:excluded]
    end
    
    no_commands do
      def post(endpoint, data)
        uri = URI("https://api.harvestapp.com/v2/#{endpoint}")
        req = Net::HTTP::Post.new(uri)
        req['Accept'] = "application/json"
        req['Content-Type'] = "application/json"
        req['Authorization'] = "Bearer #{$token}"
        req['Harvest-Account-ID'] = $acc_id
        res = Net::HTTP.start(uri.hostname, uri.port, :use_ssl => true) { |http|
          http.request(req, data.to_json)
        }
    
        JSON.parse res.body
      end
  
      def start_login_server
        server = TCPServer.new LOCAL_SERVER_PORT
  
        while session = server.accept
          request = session.gets
          
          if match = request.match(/\/\?access_token=([^&]+)&/i)
            $token = match.captures.first
      
            session.print "HTTP/1.1 200\r\n"
            session.print "Content-Type: text/html\r\n"
            session.print "\r\n"
            session.print "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"145\" height=\"28\" viewBox=\"0 0 145 28\" fill=\"currentColor\">
            <path d=\"M0 27v-26h4.9v10.4h7v-10.4h4.9v26h-4.9v-11.2h-7v11.2h-4.9zM21.5 27l6.4-26h6.3l6.2 26h-4.7l-1.2-5.5h-6.8l-1.4 5.5h-4.8zm7.1-9.9h4.9l-2.4-10.5h-.1l-2.4 10.5zM56.5 27l-4.3-10.6h-2.4v10.6h-4.9v-26h7.1c5.9 0 8.7 2.9 8.7 7.8 0 3.2-1.1 5.6-3.9 6.6l4.9 11.6h-5.2zm-6.7-14.7h2.5c2.2 0 3.5-1.1 3.5-3.6s-1.3-3.6-3.5-3.6h-2.5v7.2zM64.8 1h4.9l4.5 18.6h.1l4.5-18.6h4.8l-6.6 26h-5.6l-6.6-26zM88.2 27v-26h13.5v4.4h-8.6v6h6.5v4.4h-6.5v6.8h8.9v4.4h-13.8zM118.6 8.3c-.8-2.4-1.9-3.5-3.6-3.5-1.7 0-2.7 1.1-2.7 2.8 0 3.9 11 4.2 11 12.2 0 4.4-3 7.4-8.2 7.4-4 0-7.1-2.2-8.4-7.2l4.9-1c.6 3.1 2.4 4.2 3.8 4.2 1.7 0 3-1.1 3-3.1 0-4.9-11-4.9-11-12.1 0-4.4 2.6-7.2 7.7-7.2 4.4 0 7.1 2.6 7.9 6.2l-4.4 1.3zM144.3 1v4.4h-5.7v21.6h-4.9v-21.6h-5.7v-4.4h16.3z\"></path>
          </svg><div><p>Harvest authorized successfully, please check your command line.</p></div>"
      
            session.close
            break
          elsif request.match(/\/\?error=access_denied/i)
            puts 'Authorization failed: User denied'
            session.close
            break
          else
            puts "Unrecogonized request: #{request}"
            session.close
            break
          end
      
          session.close
        end
  
        if $token
          puts "Authorized by Harvest successfully"
          puts "Harvest token: #{$token}"
        
          uri = URI("https://id.getharvest.com/api/v2/accounts")
          req = Net::HTTP::Get.new(uri)
          req['Accept'] = "application/json"
          req['Authorization'] = "Bearer #{$token}"
        
          res = Net::HTTP.start(uri.hostname, uri.port, :use_ssl => true) { |http|
            http.request(req)
          }
        
          user = JSON.parse res.body
          $acc_id = user["accounts"].first["id"]
          puts "Harvest account ID: #{$acc_id}"
        end
      end
  
      def delete_entry(entry_id)
        Reaper.request_delete "time_entries/#{entry_id}"
      end

      def print_time_entries(from, to, entries)
        from.upto(to) do |d|
          entries[d] = [] unless entries[d]
        end
        
        entries = entries.sort.to_h
        
        headers = []
        rows = []
        daily_hours = []
        
        entries.each do |k, v|
          headers << "#{k.strftime('%a')} #{k}"
          daily_hours << (v.inject(0) { |sum, t| sum + t[:hours] })
        end

        max_row_num = entries.map { |k, v| v.size }.max
        max_row_num.times do |n|
          row = []
          entries.each do |k, v|
            if n < v.size
              t = v[n]
              task = "[#{t[:project_code]}] #{t[:project]} (#{t[:client]})\n \n- #{t[:task]}\n- Hours: #{t[:hours]}"
              row << task.scan(/.{1,15}/).join("\n")
            else
              row << ''
            end
          end
          rows << row
        end
      
        rows << daily_hours.map { |h| "Total: #{num_to_hours(h)}"}
      
        num = entries.values.flatten.size
        title = "#{num} time entries | Total hours: #{num_to_hours(daily_hours.inject(:+))}"

        table = Terminal::Table.new :title => title, :headings => headers, :rows => rows
        table.style = { :all_separators => true }
        puts table
      end

      def submit_time_entries(date_str, excluded_weekdays_str)
        mon, fri = get_week_range_from_date_str date_str
        
        if excluded_weekdays_str && !excluded_weekdays_str.empty?
          excluded_weekdays = excluded_weekdays_str
            .split(',')
            .map { |s| s.strip.downcase }
            .uniq

          valid_weekdays = %w(mon tue wed thu fri)
          unless (excluded_weekdays - valid_weekdays).empty? && excluded_weekdays.size < valid_weekdays.size
            abort "Argument 'excluded' contains invalid options. Only single or multiple values (comma separated) in #{valid_weekdays} is allowed."
          end

          excluded_weekdays_offset = excluded_weekdays.map { |d| valid_weekdays.index d }.sort
        end
        
        has_excluded = excluded_weekdays_offset != nil && !excluded_weekdays_offset.empty?

        Reaper.check_auth

        abort 'Cannot find Reaper configuration. Please run `reaper config update` first.' unless Reaper.load_config

        _, existing_entries = show date_str
      
        if existing_entries
          num = existing_entries.values.map { |v| v.size }.inject(:+)
          
          if num > 0
            puts ''

            is_clean_after_excluded = false

            if has_excluded
              entries = existing_entries.select { |k, v| !(excluded_weekdays_offset.include? (k - mon)) }
              if entries.values.map { |v| v.size }.inject(:+) > 0
                abort "You have existing time entries within the specified date range. Reaper submit won't work in this case.\nIf you are sure they can be removed, please run `reaper delete #{date_str}` first."
              else
                is_clean_after_excluded = true
              end
            end

            if !is_clean_after_excluded
              non_vocation_entries = existing_entries.select do |k, v|
                case v.size
                when 0
                  false
                when 1
                  entry = v.first
                  entry[:client] != 'Time Off' || entry[:hours] != 8
                else
                  true
                end
              end

              # all the entries are 8 hours vacation/public holiday/sick leave
              if non_vocation_entries.empty?
                case num
                when 5
                  abort "All 5 days within the specified week have been marked as 'Time Off'. Reaper submit won't work in this case.\nIf you are sure they can be removed, please run `reaper delete #{date_str}` first."
                else
                  puts "#{num} days within the specified week have been marked as 'Time Off'. Do you want to exclude them and submit time entries for the rest of the days? (Y/n)"
                  excluded_dates = existing_entries.select { |k, v| !v.empty? }.keys
                  excluded_arg = excluded_dates.map { |d| d.strftime('%a') }.join(',')

                  confirm = $stdin.gets.chomp
                  abort unless confirm == 'Y'
                  submit_time_entries date_str, excluded_arg
                  return
                end
              end

              abort "You have existing time entries within the specified date range. Reaper submit won't work in this case.\nIf you are sure they can be removed, please run `reaper delete #{date_str}` first."
            end
          end
        end

        hours_per_day = 8
        days = has_excluded ? 5 - excluded_weekdays_offset.size : 5
        
        dates = []
        5.times { |n| dates << mon + n if !has_excluded || !(excluded_weekdays_offset.include? n) }
        
        hours = []

        negative_offset_days = 0
        days.times do |_|
          # we don't want you to always work less than 8 hours, 
          # 2 is the max number of your less working days
          is_positive_offset = negative_offset_days <= 2 ? [true, false].sample : true
          negative_offset_days += 1 unless is_positive_offset
        
          offset = is_positive_offset ? $config[:daily_positive_offset] : $config[:daily_negative_offset]
          offset = round_hours(rand() * offset) * (is_positive_offset ? 1 : -1)
          hours << offset + hours_per_day
        end

        total_hours = hours.inject(:+)

        tasks = $config[:tasks]

        tasks_hours = 0
        tasks.each_with_index do |t, i|
          if i < tasks.size - 1
            t[:hours] = round_hours(total_hours * t[:percentage])
            tasks_hours += t[:hours]
          else
            t[:hours] = total_hours - tasks_hours
          end
        end

        tasks_cpy = tasks.dup
      
        entries = {}

        hours.each_with_index do |h, i|
          date = dates[i]

          slots = []
          slots_num = (h / 0.5).to_i
          slots_num.times do |n|
            t = tasks_cpy.sample
            t[:hours] -= 0.5

            slots << {
              'project_id' => t[:pid],
              'task_id' => t[:tid],
              'spent_date' => date.to_s,
              'hours' => 0.5
            }

            if t[:hours] <= 0
              tasks_cpy.delete t
            end
          end

          tasks.each do |t|
            slots_per_task = slots.select do |s|
              t[:pid] == s['project_id'] && t[:tid] == s['task_id']
            end

            if !slots_per_task.empty?
              entry = slots_per_task.first
              entry['hours'] = slots_per_task.inject(0) { |sum, s| sum + s['hours'] }
              # puts entry

              daily_tasks = entries[date] || []
              entries[date] = daily_tasks if daily_tasks.empty?

              daily_tasks << {
                :project => t[:pname],
                :project_code => t[:pcode],
                :task => t[:tname],
                :client => t[:client],
                :hours => entry['hours'],
                :project_id => t[:pid],
                :task_id => t[:tid],
                :spent_date => entry['spent_date'],
              }

              daily_tasks.shuffle!
            end
          end
        end

        print_time_entries mon, fri, entries

        puts ''

        range = "from #{mon} to #{fri}"
        range << ", #{excluded_weekdays.join(', ')} excluded" if has_excluded

        puts "A random set of time entries (#{range}) generated, submit now? (Y/n)"
        confirm = $stdin.gets.chomp
        abort 'Submit cancelled' unless confirm == 'Y'

        post_data = entries.values.flatten.map do |e|
          {
            'user_id' => $user_id,
            'project_id' => e[:project_id],
            'task_id' => e[:task_id],
            'spent_date' => e[:spent_date],
            'hours' => e[:hours]
          }
        end

        progressbar = ProgressBar.create(
          :title => 'Submitting', 
          :total => post_data.size,
          :format => '%t %c/%C %B'
        )

        post_data.each do |e|
          rsp = post 'time_entries', e
          if rsp 
            progressbar.increment
          else
            abort "Submit request failed. Your submit actions may not be completed. Please run `reaper show #{date_str}` to check."
          end
        end

        puts "#{post_data.size} time entries submitted successfully. You can run `reaper show #{date_str}` to check."
      end

      # helpers
      
      def num_to_hours(num)
        num
      end
  
      def round_hours(hours)
        (hours * 2).round / 2.0
      end
  
      def get_last_monday
        today = Date.today
        wday = today.wday
        wday = 7 if wday == 0
        last_mon = today - (wday - 1)
      end

      def get_mon_by_date(date)
        wday = date.wday
        wday = 7 if wday == 0
        date - (wday - 1)
      end

      def get_mon_of_this_week
        get_mon_by_date Date.today
      end

      def get_mon_of_last_week
        get_mon_of_this_week - 7
      end

      def get_week_range_from_date_str(date_str)
        case date_str
        when 'current'
          mon = get_mon_of_this_week
        when 'last'
          mon = get_mon_of_last_week
        else
          date_str = Date.today.year.to_s << date_str if date_str.size < 5
  
          begin
            date = Date.strptime(date_str, '%Y%m%d')
          rescue
            abort 'Please enter a valid date string'
          end
  
          mon = get_mon_by_date date if date
        end
        
        return mon, (mon + 4)
      end
    end

    desc "donate", "Buy me a milktea ❤️"
    def donate
      puts 'If you think Reaper saves your time, please consider buying the author a milktea ❤️'
      pay_img = File.join Reaper.root, 'assets/alipay.jpg'
      `qlmanage -p #{pay_img} 2>/dev/null`
    end
  
    desc "version", "Show current Reaper version"
    def version
    sickle = "MMMMMMMMMMMMMMMMMMMMMMMMMMMNdyo//oymMMMMMMMMMMMMMM
MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMmo` `/yNMMMMMMMMMM
MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMs`   :hMMMMMMMM
MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMN- `: .yMMMMMM
MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM: :d: -dMMMM
MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMN. sMh` oMMM
MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMy .MMN- /MM
MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM  dMMN- oM
MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM` hMMMm` d
MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM  dMMMM+ :
MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMy `MMMMMd `
MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMN. sMMMMMm  
MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMN- /MMMMMMy .
MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMh. oMMMMMMM. s
MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMNy- -dMMMMMMM+ -M
MMMMMMMMMMMMd/ -/oydmNMMMMMMNmho: `/dMMMMMMMM+ .NM
MMMMMMMMMMd:  syo/-.   ``.`  `./odMMMMMMMMMm: :NMM
MMMMMMMMd: .+` /dMMMMNmmddmmNMMMMMMMMMMMMNo``sMMMM
MMMMMMd: -yMMNy` .odMMMMMMMMMMMMMMMMMMMmo` +NMMMMM
MMMMd:   -----. -o- ./ymMMMMMMMMMMMNdo- .oNMMMMMMM
MMd: -yhhhh+  -hMMMNy+-  .:/+oo+/:. `:odMMMMMMMMMM
m:  `:::::- -hMMMMMMMMMMmhsoo++ooshmMMMMMMMMMMMMMM
` +ssss:  -hMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM
. +mNy- -hMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM
N+.  `/hMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM"

      slogan = 'Keep your PM away (TM)'
      slogan_len = slogan.length + 4
      puts "#{sickle}\n\n#{'*' * slogan_len}\n* #{slogan} *\n#{'*' * slogan_len}\n\nReaper: A smart Harvest filling helper. \nVersion #{Reaper::VERSION}"
    end
  end
end
