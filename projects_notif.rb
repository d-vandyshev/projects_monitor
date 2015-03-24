# Conventions:
# fr - freelance.com
# fl - freelance.ru

class ProjectMonitor
  require 'nokogiri'
  require 'open-uri'
  require 'net/smtp'
  require 'inifile'

  def initialize(attr)
    @sent_projects = Array.new

    conf = IniFile.load(attr[:config])
    abort "Unable to read config file #{CONFIG_FILE}" unless conf
    @fr_monitor = conf[:main]['FR_monitor']
    @fl_monitor = conf[:main]['FL_monitor']
    @fr_skills = conf[:main]['fr_skills'].split /,\s*/
    @fl_match  = conf[:main]['fl_match'].split /,\s*/
    @sleeptime = conf[:main]['sleeptime'].to_i
    @notif = Notif.new(
        smtp_host: conf[:mail]['smtp_host'],
        smtp_port: conf[:mail]['smtp_port'].to_i,
        login:     conf[:mail]['login'],
        pass:      conf[:mail]['pass']
    )

    @hello_hour, @hello_minute = conf[:main]['hellotime'].split(':')
    @notif.hello
    @hello_send_day = Time.new(Time.now.year, Time.now.month, Time.now.day)
    @sent_hello = true
  end

  def start
    puts 'start ProjectsMonitor'
    while true do
      @notif.hello if time_for_hello?

      begin
        @projects = Array.new

        # http://freelancer.com
        @projects += freelancer_com if @fr_monitor

        # http://fl.ru
        @projects += fl_ru if @fl_monitor

      rescue => e
        puts "Error while get projects!"
        e_mess = "#{e.class}: #{e.message}"
        puts e_mess
        @notif.send 'Projects Notifier: Ошибка получения проектов!', e_mess
      end

      # delete sent projects from array
      delete_sent!

      puts Time.now.to_s + " ProjectsMonitor receives #{ @projects.length } projects"
      # send projects via email
      @projects.each do |p|
        subject = "Subject: #{ p.source }: #{ p.title }"
        @notif.send subject, p.to_s
      end

      sleep @sleeptime
    end
  end

  private

  def delete_sent!
    @projects.delete_if { |p| @sent_projects.include?(p.desc) }
    @projects.each { |p| @sent_projects << p.desc }
    @sent_projects = @sent_projects.pop(100)
  end

  def freelancer_com
    url = 'https://www.freelancer.com/jobs/1/'
    page = Nokogiri::HTML(open(url))
    projects = Array.new
    page.css('tr.project-details').each do |tr|
      td = tr.child

      #Title and URL
      td = td.next_element
      td.css('ul.promotions').remove
      title = td.css('a').text.strip!
      url = td.css('a').attribute('href')

      #Description
      td = td.next_element
      desc = td.text

      #Bids
      td = td.next_element
      bids = td.text

      #Skills
      td = td.next_element
      a = td.css('a').map { |a| a.text }
      skills = @fr_skills & a
      next if skills.count == 0

      #Skip Start and End
      td = td.next_element
      td = td.next_element

      #Price
      td = td.next_element
      price = td.text

      #Source
      source = :FR

      projects << Project.new(title, url, desc, bids, skills, price, source)
    end
    projects
  end

  def fl_ru
    base_url = 'https://www.fl.ru'
    user_agent = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/38.0.2125.101 YaBrowser/14.12.2125.8016 Safari/537.36'
    text = File.read open(base_url + '/projects/', 'User-Agent' => user_agent)
    text.encode!('utf-8', 'windows-1251')
    text.gsub! '\');</script>', ''
    text.gsub! '<script type="text/javascript">document.write(\'', ''
    page = Nokogiri::HTML(text)

    projects = Array.new
    page.css('div#projects-list div.b-post').each do |i|
      #Title
      title = i.css('h2 a').text

      # URL
      url = base_url + i.css('h2 a').attribute('href')

      #Description
      desc = i.css('div.b-post__body').text.strip!
      #Find keywords matches
      next unless @fl_match.any? { |w| desc =~ /#{w}/i }

      #Bids
      bids = i.css('a.b-post__link_bold.b-page__desktop').text

      #Price
      price = i.css('.b-post__price').text.strip!

      #Source
      source = :FL

      projects << Project.new(title, url, desc, bids, '', price, source)
    end
    projects
  end

  def time_for_hello?
    # Switch to next day
    timeday = Time.new(Time.now.year, Time.now.month, Time.now.day)
    if (timeday <=> @hello_send_day) == 1
      @hello_send_day = timeday
      @sent_hello = false
    end

    # Check for hello time
    now = Time.new
    today_send_time = Time.new(Time.now.year, Time.now.month, Time.now.day, @hello_hour, @hello_minute)
    if !@sent_hello and (now <=> today_send_time) == 1
      @sent_hello = true
      true
    else
      false
    end
  end

end

class Project
  attr_reader :source, :title, :desc

  def initialize(title, url, desc, bids, skills, price, source)
    @title, @url, @desc, @bids, @skills, @price, @source = title, url, desc, bids, skills, price, source
    @mail_subject = "Subject: #{ @source }: #{ @title }"
  end

  def to_s
    "Price:#{ @price }\nSkills:#{ @skills }\nUrl: #{ @url }\nBids:#{ @bids }\nDesc:#{ @desc }"
  end
end

class Notif

  def initialize(attr)
    @login      = attr[:login]
    @pass       = attr[:pass]
    @smtp_host  = attr[:smtp_host]
    @smtp_port  = attr[:smtp_port]
  end

  def hello
    send 'Subject: Hello from Projects Notifier', 'Have a nice day'
  end

  def send(subject, body)
    msg = "#{ subject }\n\n#{ body }"
    begin
      smtp = Net::SMTP.new @smtp_host, @smtp_port
      smtp.enable_starttls
      smtp.start('list.ru', @login, @pass, :plain) do
        smtp.send_message(msg, @login, @login)
      end
    rescue => e
        puts 'Error while send email!'
        e_mess = "#{e.class}: #{e.message}"
        puts e_mess
    end
    sleep 1
  end
end

pm = ProjectMonitor.new config: 'projects_notif.ini'
pm.start
