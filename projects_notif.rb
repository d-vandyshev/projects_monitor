# Conventions:
# fr - freelance.com
# fl - freelance.ru

class ProjectMonitor
  require 'nokogiri'
  require 'open-uri'
  require 'net/smtp'
  require 'inifile'
  require 'rss'
  require 'logger'

  Project = Struct.new(:title, :url, :desc, :bids, :skills, :price, :source) do
    def to_s
      "Price:#{price}\nSkills:#{skills}\nUrl: #{url}\nBids:#{bids}\nDesc:#{desc}"
    end
  end

  def initialize(config_file)
    @conf = PMConfig.new config_file
    @conf.read

    @notif = Notif.new(
        smtp_host: @conf.mail.smtp_host,
        smtp_port: @conf.mail.smtp_port,
        login: @conf.mail.login,
        pass: @conf.mail.pass
    )

    @log = Logger.new(File.basename(__FILE__, '.*') + '.log', 0, 1024 * 1024)

    @hello_send_day = Time.new(Time.now.year, Time.now.month, Time.now.day)
    @sent_hello = false
  end

  def start
    @log.info 'start ProjectsMonitor'
    threads = []
    threads << Thread.new { collect_projects }
    sleep 5
    threads << Thread.new { check_state_from_email }
    threads.each do |t|
      t.abort_on_exception = true
      t.join
    end
  end

  private

  def collect_projects
    sent_projects = []

    loop do
      @conf.read

      sources = []
      @conf.sources.each do |source|
        sources << case source.name
                     when :fl_ru
                       FL_ru.new source.uri
                     when :freelancer
                       Freelancer.new source.uri
                     when :odesk
                       Odesk.new source.uri
                     else
                       abort 'ERROR. Unknown method'
                   end
      end

      @notif.hello if time_for_hello?

      projects = []
      begin
        projects += freelancer_com if @conf.fr_monitor
        projects += fl_ru if @conf.fl_monitor
        projects += odesk_com if @conf.od_monitor
      rescue => e
        @log.error 'Error while get projects!'
        e_mess = "#{e.class}: #{e.message}"
        @log.error e_mess
        @notif.send 'Projects Notifier: Ошибка получения проектов!', e_mess
      end
      # delete sent project to not send dups of projects
      projects.delete_if { |p| sent_projects.include?(p.desc) }
      projects.each { |p| sent_projects << p.desc }
      sent_projects = sent_projects.pop(100)

      @log.info Time.now.to_s + " ProjectsMonitor receives #{projects.length} projects"
      send projects via email
      projects.each do |p|
        subject = "Subject: #{ p.source }: #{ p.title }"
        @notif.send subject, p.to_s
      end

      sleep @conf.sleep_time
    end
  end

  def check_state_from_email
    @log.info 'run check_state_from_email'
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
    hello_hour, hello_minute = @conf.hello_time.split(':')
    today_send_time = Time.new(Time.now.year, Time.now.month, Time.now.day, hello_hour, hello_minute)
    if !@sent_hello and (now <=> today_send_time) == 1
      @sent_hello = true
      true
    else
      false
    end
  end
end

class PMConfig
  attr_reader :mail, :sources, :sleep_time, :hello_time

  Mail = Struct.new(:login, :pass, :smtp_host, :smtp_port, :imap_host)

  def initialize(config_file)
    @config_file = config_file
  end

  def read
    c = IniFile.load(@config_file)
    abort "Unable to read ini-file #{@config_file}" unless c
    @mail = Mail.new(c[:mail]['login'],
                     c[:mail]['pass'],
                     c[:mail]['smtp_host'],
                     c[:mail]['smtp_port'],
                     c[:mail]['imap_host'])
    @sources = []
    @sources << Struct.new(:name,
                           :monitor,
                           :uri,
                           :skills).new(:freelancer,
                                        c[:freelancer]['monitor'],
                                        c[:freelancer]['uri'],
                                        c[:freelancer]['skills'])
    @sources << Struct.new(:name,
                           :monitor,
                           :uri,
                           :match).new(:fl_ru,
                                       c[:fl_ru]['monitor'],
                                       c[:fl_ru]['uri'],
                                       c[:fl_ru]['match'])
    @sources << Struct.new(:name,
                           :monitor,
                           :uri).new(:odesk,
                                     c[:odesk]['monitor'],
                                     c[:odesk]['uri'])

    @sleep_time = c[:main]['sleep_time'].to_i
    @hello_time = c[:main]['hello_time']
  end
end

class Notif
  def initialize(attr)
    @login = attr[:login]
    @pass = attr[:pass]
    @smtp_host = attr[:smtp_host]
    @smtp_port = attr[:smtp_port]
  end

  def hello
    send 'Subject: Hello from Projects Notifier', 'Have a nice day'
  end

  def send(subject, body)
    return "ok"
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

class Source
  def initialize(uri)
    @uri = uri
  end
end

class FL_ru < Source
  def get_content
    user_agent = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/38.0.2125.101 YaBrowser/14.12.2125.8016 Safari/537.36'
    text = File.read open(@uri + '/projects/', 'User-Agent' => user_agent)
    text.encode!('utf-8', 'windows-1251')
    text.gsub! '\');</script>', ''
    text.gsub! '<script type="text/javascript">document.write(\'', ''
    @page = Nokogiri::HTML(text)
  end

  def parse_projects
    projects = []
    @page.css('div#projects-list div.b-post').each do |i|
      p = Project.new
      p.title = i.css('h2 a').text
      p.url = base_url + i.css('h2 a').attribute('href')
      p.desc = i.css('div.b-post__body').text.strip!

      #Find keywords matches
      next unless @conf.fl_match.any? { |w| p.desc =~ /#{w}/i }
      p.bids = i.css('a.b-post__link_bold.b-page__desktop').text
      p.price = i.css('.b-post__price').text.strip!
      p.source = :FL
      projects << p
    end
    projects
  end
end

class Freelancer < Source
  def get_content
    @page = Nokogiri::HTML(open(@uri))
  end

  def parse_projects
    projects = []
    @page.css('tr.project-details').each do |tr|
      p = Project.new
      td = tr.child

      #Title and URL
      td = td.next_element
      td.css('ul.promotions').remove
      p.title = td.css('a').text.strip!
      p.url = td.css('a').attribute('href')

      td = td.next_element
      p.desc = td.text
      td = td.next_element
      p.bids = td.text

      td = td.next_element
      a = td.css('a').map { |a| a.text }
      p.skills = @conf.fr_skills & a
      next if p.skills.count == 0

      td = td.next_element
      td = td.next_element
      td = td.next_element
      p.price = td.text
      p.source = :FR
      projects << p
    end
    projects
  end
end

class Odesk < Source
  def get_content
    @page = open(URI(URI.encode(@uri)))
  end

  def parse_projects
    feed = RSS::Parser.parse(@page)
    projects = []
    feed.items.each do |item|
      projects << Project.new(item.title, item.link, item.description, '-', '', '', :OD)
    end
    projects
  end
end

ProjectMonitor.new('projects_notif.ini').start
