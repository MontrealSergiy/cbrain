# Filters added to this controller apply to all controllers in the application.
# Likewise, all the methods added will be available for all controllers.
#
# CBRAIN project
#
# $Id$

# Superclass to all *BrainPortal* controllers. Contains
# helper methods for checking various aspects of the current
# session.

require 'authenticated_system'

class ApplicationController < ActionController::Base

  Revision_info=CbrainFileRevision[__FILE__]

  include AuthenticatedSystem
  include ExceptionLogger::ExceptionLoggable
  include BasicFilterHelpers
  
  rescue_from Exception, :with => :log_exception_handler

  helper_method :check_role, :not_admin_user, :current_session, :current_project
  helper_method :to_localtime, :pretty_elapsed, :pretty_past_date, :pretty_size, :red_if, :html_colorize
  helper_method :view_pluralize
  helper        :all # include all helpers, all the time

  before_filter :always_activate_session
  before_filter :set_cache_killer
  before_filter :check_if_locked
  before_filter :prepare_messages
  before_filter :set_session
  before_filter :password_reset
  before_filter :adjust_system_time_zone
  before_filter :api_validity_check
  around_filter :catch_cbrain_message, :activate_user_time_zone
    
  # See ActionController::RequestForgeryProtection for details
  # Uncomment the :secret if you're not using the cookie session store
  protect_from_forgery :secret => 'b5e7873bd1bd67826a2661e01621334b'
  
  

  ########################################################################
  # Controller Filters
  ########################################################################

  private
  
  # Returns the name of the model class associated with a given contoller. By default
  # takes the name from the name of the controller, but can be redefined in subclasses
  # as needed.
  def resource_class
    @resource_class ||= Class.const_get self.class.to_s.sub(/Controller$/, "").singularize
  end
  
  # Convenience method to determine wether a given model has the provided attribute.
  # Note: mainly for security reasons; this allows easy sanitization of parameters related
  # to attributes.
  def table_column?(model, attribute)
    column = attribute
    klass = Class.const_get model.to_s.classify
    
    klass.columns_hash[column]
  rescue
    false   
  end
  
  # Easy and safe filtering based on individual attributes or named scopes.
  # Simply adding <att>=<val> to a URL on an index page that uses this method
  # will automatically filter as long as <att> is a valid attribute or named
  # scope.
  def base_filtered_scope(filtered_scope = resource_class.scoped({}))
    @filter_params["filter_hash"].each do |att, val|
      if filtered_scope.scopes[att.to_sym] && att.to_sym != :scoped
        filtered_scope = filtered_scope.send(att, *val)
      elsif table_column?(resource_class, att)
        filtered_scope = filtered_scope.scoped(:conditions => {att => val})
      else
        @filter_params["filter_hash"].delete att
      end
    end
    if @filter_params["sort_hash"] && @filter_params["sort_hash"]["order"] && table_column?(*@filter_params["sort_hash"]["order"].split("."))
      filtered_scope = filtered_scope.order("#{@filter_params["sort_hash"]["order"]} #{@filter_params["sort_hash"]["dir"]}")
    end
    filtered_scope
  end
  
  def always_activate_session
    session[:cbrain_toggle] = (1 - (session[:cbrain_toggle] || 0))
    true
  end

  # This method adjust the Rails app's time zone in the rare
  # cases where the admin has changed it in the DB using the
  # interface.
  def adjust_system_time_zone
    myself = RemoteResource.current_resource
    syszone = myself.time_zone
    return true unless syszone && ActiveSupport::TimeZone[syszone]
    if Time.zone.blank? || Time.zone.name != syszone
      #puts "\e[1;33;41mRESETTING TIME ZONE FROM '#{Time.zone.name rescue "unset"}' to '#{syszone}'.\e[0m"
      Time.zone = ActiveSupport::TimeZone[syszone]
      CbrainRailsPortal::Application.config.time_zone = syszone
      #Rails::Initializer.new(Rails.configuration).initialize_time_zone
    #else
    #  testtime = Userfile.first.created_at
    #  puts "\e[1;33;41mTIME ZONE STAYS SAME: #{syszone} TEST: #{testtime}\e[0m"
    end
    true
  end

  # This method wraps ALL other controller methods
  # into a sandbox where the value for Time.zone is
  # temporarily switched to the current user's time zone,
  # if it is defined. Otherwise, the Rails application's
  # time zone is used.
  def activate_user_time_zone #:nodoc:
    return yield unless current_user # nothing to do if no user logged in
    userzone = current_user.time_zone
    return yield unless userzone && ActiveSupport::TimeZone[userzone] # nothing to do if no user zone or zone is incorrect
    return yield if Time.zone && Time.zone.name == userzone # nothing to do if user's zone is same as system's
    Time.use_zone(ActiveSupport::TimeZone[userzone]) do
      yield
    end
  end

  #Prevents pages from being cached in the browser. 
  #This prevents users from being able to access pages after logout by hitting
  #the 'back' button on the browser.
  #
  #NOTE: Does not seem to be effective for all browsers.
  def set_cache_killer
    # (no-cache) Instructs the browser not to cache and get a fresh version of the resource
    # (no-store) Makes sure the resource is not stored to disk anywhere - does not guarantee that the 
    # resource will not be written
    # (must-revalidate) the cache may use the response in replying to a subsequent reques but if the resonse is stale
    # all caches must first revalidate with the origin server using the request headers from the new request to allow
    # the origin server to authenticate the new reques
    # (max-age) Indicates that the client is willing to accept a response whose age is no greater than the specified time in seconds. 
    # Unless max- stale directive is also included, the client is not willing to accept a stale response.
    response.headers["Last-Modified"] = Time.now.httpdate
    response.headers["Expires"] = "#{1.year.ago}"
    # HTTP 1.0
    # When the no-cache directive is present in a request message, an application SHOULD forward the request 
    # toward the origin server even if it has a cached copy of what is being requested
    response.headers["Pragma"] = "no-cache"
    # HTTP 1.1 'pre-check=0, post-check=0' (IE specific)
    response.headers["Cache-Control"] = 'no-store, no-cache, must-revalidate, max-age=0, pre-check=0, post-check=0'
  end

  # Set up the current_session variable. Mainly used to set up the filter hash to be
  # used by index actions.
  def set_session
    current_controller = params[:controller]
    params[current_controller] ||= {}
    clear_params       = params.keys.select{ |k| k.to_s =~ /^clear_/}
    clear_param_key    = clear_params.first
    clear_param_value  = params[clear_param_key]
    if clear_param_key
      params[current_controller][clear_param_key.to_s] = clear_param_value
    end
    clear_params.each { |p| params.delete p.to_s }
    if params[:update_filter]
      update_filter      = params[:update_filter].to_s
      parameters = request.query_parameters.clone
      parameters.delete "update_filter"
      if update_filter =~ /_hash$/
        params[current_controller][update_filter] = parameters
      else
        params[current_controller] = parameters
      end
      params.delete "update_filter"
      parameters.keys.each { |p|  params.delete p}
    end
    current_session.update(params)
    @filter_params = current_session.params_for(params[:controller])
  end
  
  # Force the user to change their password if they just did a reset.
  def password_reset
    if current_user && current_user.password_reset && params[:controller] != "sessions"
      unless params[:controller] == "users" && (params[:action] == "show" || params[:action] == "update")
        flash[:notice] = "Please reset your password."
        redirect_to user_path(current_user)
      end
    end
  end
  
  ########################################################################
  # CBRAIN Exception Handling (Filters)
  ########################################################################

  #Catch and display cbrain messages
  def catch_cbrain_message
    begin
      yield # try to execute the controller/action stuff

    # Record not accessible
    rescue ActiveRecord::RecordNotFound => e
      raise if Rails.env == 'development' #Want to see stack trace in dev.
      flash[:error] = "The object you requested does not exist or is not accessible to you."
      respond_to do |format|
        format.html { redirect_to default_redirect }
        format.js   { render :partial  => "shared/flash_update", :status  => 404 } 
        format.xml  { render :xml => {:error  => e.message}, :status => 404 }
      end

    # Action not accessible
    rescue ActionController::UnknownAction => e
      raise if Rails.env == 'development' #Want to see stack trace in dev.
      flash[:error] = "The page you requested does not exist."
      respond_to do |format|
        format.html { redirect_to default_redirect }
        format.js   { render :partial  => "shared/flash_update", :status  => 400 } 
        format.xml  { render :xml => {:error  => e.message}, :status => 400 }
      end

    # Internal CBRAIN errors
    rescue CbrainException => cbm
      if cbm.is_a? CbrainNotice
         flash[:notice] = cbm.message    # + "\n" + cbm.backtrace[0..5].join("\n")
      else
         flash[:error]  = cbm.message    # + "\n" + cbm.backtrace[0..5].join("\n")
      end
      logger.error "CbrainException for controller #{params[:controller]}, action #{params[:action]}: #{cbm.class} #{cbm.message}"
      respond_to do |format|
        format.html { redirect_to cbm.redirect || default_redirect }
        format.js   { render :partial  => "shared/flash_update", :status  => cbm.status } 
        format.xml  { render :xml => {:error  => cbm.message}, :status => cbm.status }
      end

    # Anything else is serious
    rescue => ex
      raise unless Rails.env == 'production' #Want to see stack trace in dev. Also will log it in exception logger

      # Note that send_internal_error_message will also censure :password from the params hash
      Message.send_internal_error_message(current_user, "Exception Caught", ex, params) rescue true
      log_exception(ex) # explicit logging in exception logger, since we won't re-raise it now.
      flash[:error] = "An error occurred. A message has been sent to the admins. Please try again later."
      logger.error "Exception for controller #{params[:controller]}, action #{params[:action]}: #{ex.class} #{ex.message}"
      respond_to do |format|
        format.html { redirect_to default_redirect }
        format.js   { render :partial  => "shared/flash_update", :status  => 500 } 
        format.xml  { render :xml => {:error  => e.message}, :status => 500 }
      end

    end

  end
  
  # Redirect to the index page if available and wasn't the source of
  # the exception, otherwise to welcome page.
  def default_redirect
    final_resting_place = { :controller => "portal", :action => "welcome" }
    if self.respond_to?(:index) && params[:action] != "index"
      { :action => :index }
    elsif final_resting_place.keys.all? { |k| params[k] == final_resting_place[k] }
      "/500.html" # in case there's an error in the welcome page itself
    else
      url_for(final_resting_place)
    end
  end
  
  ########################################################################
  # CBRAIN Messaging System Filters
  ########################################################################

  # Redirect normal users to the login page if the portal is locked.
  def check_if_locked
    if BrainPortal.current_resource.portal_locked?
      flash.now[:error] ||= ""
      flash.now[:error] += "\n" unless flash.now[:error].blank?
      flash.now[:error] += "This portal is currently locked for maintenance."
      message = BrainPortal.current_resource.meta[:portal_lock_message]
      flash.now[:error] += "\n#{message}" unless message.blank?
      unless current_user && current_user.has_role?(:admin)
        respond_to do |format|
          format.html {redirect_to logout_path unless params[:controller] == "sessions"}
          format.xml  {render :xml => {:message => message}, :status => 503}
        end
      end
    end
  end
    
  # Find new messages to be displayed at the top of the page.
  def prepare_messages
    return unless current_user
    return if     request.format.blank?
    return unless request.format.to_sym == :html || params[:controller] == 'messages'
    
    @display_messages = []
    
    unread_messages = current_user.messages.where( :read => false ).order( "last_sent DESC" )
    @unread_message_count = unread_messages.count
    
    unread_messages.each do |mess|
      if mess.expiry.blank? || mess.expiry > Time.now
        if mess.critical? || mess.display?
          @display_messages << mess
          unless mess.critical?
            mess.update_attributes(:display  => false)
          end
        end
      else  
        mess.update_attributes(:read  => true)
      end
    end
  end
    
  ########################################################################
  # Helpers
  ########################################################################

  #Checks that the current user's role matches +role+.
  def check_role(role)
    current_user && current_user.role.to_sym == role.to_sym
  end
  
  #Checks that the current user is not the default *admin* user.
  def not_admin_user(user)
    user && user.login != 'admin'
  end
  
  #Checks that the current user is the same as +user+. Used to ensure permission
  #for changing account information.
  def edit_permission?(user)
    result = current_user && user && (current_user == user || current_user.role == 'admin' || (current_user.has_role?(:site_manager) && current_user.site == user.site))
  end
  
  #Returns the current session as a CbrainSession object.
  def current_session
    @cbrain_session ||= CbrainSession.new(session, params, request.env['rack.session.record'] )
  end
  
  #Returns currently active project.
  def current_project
    return nil unless current_session[:active_group_id]
    
    if !@current_project || @current_project.id.to_i != current_session[:active_group_id].to_i
      @current_project = Group.find_by_id(current_session[:active_group_id])
      current_session[:active_group_id] = nil if @current_project.nil?
    end
    
    @current_project
  end
  
  #Helper method to render and error page. Will render public/<+status+>.html
  def access_error(status)
    respond_to do |format|
      format.html { render(:file => (Rails.root.to_s + '/public/' + status.to_s + '.html'), :status  => status, :layout => false ) }
      format.xml  { head status }
    end 
  end
  
  #################################################################################
  # Date/Time Helpers
  #################################################################################
  
  #Converts any time string or object to the format 'yyyy-mm-dd hh:mm:ss'.
  def to_localtime(stringtime, what = :date)
     loctime = stringtime.is_a?(Time) ? stringtime : Time.parse(stringtime.to_s)
     loctime = loctime.in_time_zone # uses the user's time zone, or the system if not set. See activate_user_time_zone()
     if what == :date || what == :datetime
       date = loctime.strftime("%Y-%m-%d")
     end
     if what == :time || what == :datetime
       time = loctime.strftime("%H:%M:%S %Z")
     end
     case what
       when :date
         return date
       when :time
         return time
       when :datetime
         return "#{date} #{time}"
       else
         raise "Unknown option #{what.to_s}"
     end
  end

  # Returns a string that represents the amount of elapsed time
  # encoded in +numseconds+ seconds.
  #
  # 0:: "0 seconds"
  # 1:: "1 second"
  # 7272:: "2 hours, 1 minute and 12 seconds"
  def pretty_elapsed(numseconds,options = {})
    remain    = numseconds.to_i
    is_short  = options[:short]
    
    
    return "0 seconds" if remain <= 0

    numyears = remain / 1.year.to_i
    remain   = remain - ( numyears * 1.year.to_i   )
    
    nummos   = remain / 1.month
    remain   = remain - ( nummos * 1.month   )

    numweeks = remain / 1.week
    remain   = remain - ( numweeks * 1.week   )

    numdays  = remain / 1.day
    remain   = remain - ( numdays  * 1.day    )

    numhours = remain / 1.hour
    remain   = remain - ( numhours * 1.hour   )

    nummins  = remain / 1.minute
    remain   = remain - ( nummins  * 1.minute )

    numsecs  = remain

    components = [
      [numyears, is_short ? "y" : "year"],
      [nummos,   is_short ? "mo" : "month"],
      [numweeks, is_short ? "w" : "week"],
      [numdays,  is_short ? "d" : "day"],
      [numhours, is_short ? "h" : "hour"],
      [nummins,  is_short ? "m" : "minute"],
      [numsecs,  is_short ? "s" : "second"]
    ]

    
   components = components.select { |c| c[0] > 0 }
   components.pop   while components.size > 0 && components[-1] == 0 
   components.shift while components.size > 0 && components[0]  == 0 
   
    if options[:num_components]
      while components.size > options[:num_components]
        components.pop
      end
    end

    final = ""

    while components.size > 0
      comp = components.shift
      num  = comp[0]
      unit = comp[1]
      if !is_short
        unit += "s" if num > 1
        unless final.blank?
          if components.size > 0
            final += ", "
          else
            final += " and "
          end
        end
      end
      final += !is_short ? "#{num} #{unit}" : "#{num}#{unit}"
    end

    final
  end

  # Returns +pastdate+ as as pretty date or datetime with an
  # amount of time elapsed since then expressed in parens
  # just after it, e.g.,
  #
  #    "2009-12-31 11:22:33 (3 days 2 hours 27 seconds ago)"
  def pretty_past_date(pastdate, what = :datetime)
    loctime = pastdate.is_a?(Time) ? pastdate : Time.parse(pastdate.to_s)
    locdate = to_localtime(pastdate,what)
    elapsed = pretty_elapsed(Time.now - loctime)
    "#{locdate} (#{elapsed} ago)"
  end
  
  # Format a byte size for display in the view.
  # Returns the size as one format of
  #
  #   "12.3 Gb"
  #   "12.3 Mb"
  #   "12.3 Kb"
  #   "123 bytes"
  #   "unknown"     # if size is blank
  #
  # Note that these are the DECIMAL SI prefixes.
  #
  # The option :blank can be given a
  # string value to return if size is blank,
  # instead of "unknown".
  def pretty_size(size, options = {})
    if size.blank?
      options[:blank] || "unknown"
    elsif size >= 1_000_000_000
      sprintf("%6.1f Gb", size/(1_000_000_000.0)).strip
    elsif size >=     1_000_000
      sprintf("%6.1f Mb", size/(    1_000_000.0)).strip
    elsif size >=         1_000
      sprintf("%6.1f Kb", size/(        1_000.0)).strip
    else
      sprintf("%d bytes", size).strip
    end 
  end

  # Returns one of two things depending on +condition+:
  # If +condition+ is FALSE, returns +string1+
  # If +condition+ is TRUE, returns +string2+ colorized in red.
  # If no +string2+ is supplied, then it will be considered to
  # be the same as +string1+.
  # Options can be use to specify other colors (as :color1 and
  # :color2, respectively)
  #
  # Examples:
  #
  #     red_if( ! is_alive? , "Alive", "Down!" )
  #
  #     red_if( num_matches == 0, "#{num_matches} found" )
  def red_if(condition, string1, string2 = string1, options = { :color2 => 'red' } )
    if condition
      color = options[:color2] || 'red'
      string = string2 || string1
    else
      color = options[:color1]
      string = string1
    end
    return color ? html_colorize(string,color) : string.html_safe
  end

  # Returns a string of text colorized in HTML.
  # The HTML code will be in a SPAN, like this:
  #   <SPAN STYLE="COLOR:color">text</SPAN>
  # The default color is 'red'.
  def html_colorize(text, color = "red", options = {})
    "<span style=\"color: #{color}\">#{text}</span>".html_safe
  end

  # Calls the view helper method 'pluralize'
  def view_pluralize(*args) #:nodoc:
    ApplicationController.helpers.pluralize(*args)
  end
  
  #Directive to be used in controllers to make
  #actions available to the API
  def self.api_available(actions = :all)
    @api_action_code = actions
  end
  
  def self.api_actions #:nodoc:
    unless @api_actions
      @api_actions ||= []
      actions = @api_action_code || :none
      case actions
      when :all
        @api_actions = self.instance_methods(false).map(&:to_sym)
      when :none
        @api_actions = []
      when Symbol
        @api_actions = [actions]
      when Array
        @api_actions = actions.map(&:to_sym)
      when Hash
        if actions[:only]
          only_available = actions[:only]
          only_available = [only_available] unless only_available.is_a?(Array)
          only_available.map!(&:to_sym)
          @api_actions = only_available
        elsif actions[:except]
          unavailable = actions[:except]
          unavailable = [unavailable] unless unavailable.is_a?(Array)
          unavailable.map!(&:to_sym)
          @api_actions = self.instance_methods(false).map(&:to_sym) - unavailable
        end
      else
        if actions.respond_to?(:to_sym)
          @api_actions << actions.to_sym
        else
          cb_error "Invalid action definition: #{actions}."
        end
      end
    end
    
    @api_actions
  end

  #Before filter that checks that blocks certain actions
  #from the API
  def api_validity_check
    if request.format && request.format.to_sym == :xml
      valid_actions = self.class.api_actions || []
      current_action = params[:action].to_sym
      
      unless valid_actions.include? current_action
        render :xml => {:error  => "Action '#{current_action}' not available to API. Available actions are #{valid_actions.inspect}"}, :status  => :bad_request 
      end
    end
  end

  # Utility method that allows a controller to add
  # meta information to a +target_object+ based on
  # the content of a form which has inputs named
  # like "meta[key1]" "meta[key2]" etc. The list of
  # keys we are looking for are supplied in +meta_keys+ ;
  # any other values present in the params[:meta] will
  # be ignored.
  #
  # Example: let's say that when posting to update object @myobj,
  # the also form sent this to the controller:
  #
  #   params = { :meta => { :abc => "2", :def => 'z', :xyz => 'A' } ... }
  #
  # Then calling
  #
  #   add_meta_data_from_form(@myobj, [ :def, :xyz ])
  #
  # will result in two meta data pieces of information added
  # to the object @myobj, like this:
  #
  #   @myobj.meta[:def] = 'z'
  #   @myobj.meta[:xyz] = 'A'
  #
  # See ActRecMetaData for more information.
  def add_meta_data_from_form(target_object, meta_keys = [], myparams = params)
    return true if meta_keys.empty?
    target_object.update_meta_data(myparams[:meta] || {}, meta_keys)
  end

end

# Patch: Load all models so single-table inheritance works properly.
begin
  Dir.chdir(File.join(Rails.root.to_s, "app", "models")) do
    Dir.glob("*.rb").each do |model|
      model.sub!(/.rb$/,"")
      require_dependency "#{model}.rb" unless Object.const_defined? model.classify
    end
  end
  
  #Load userfile file types
  Dir.chdir(File.join(Rails.root.to_s, "app", "models", "userfiles")) do
    Dir.glob("*.rb").each do |model|
      model.sub!(/.rb$/,"")
      require_dependency "#{model}.rb" unless Object.const_defined? model.classify
    end
  end
rescue => error
  if error.to_s.match(/Mysql::Error.*Table.*doesn't exist/i)
    puts "Skipping model load:\n\t- Database table doesn't exist yet. It's likely this system is new and the migrations have not been run yet."
  elsif error.to_s.match(/Unknown database/i)
    puts "Skipping model load:\n\t- System database doesn't exist yet. It's likely this system is new and the migrations have not been run yet."
  else
    raise
  end
end

