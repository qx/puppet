require 'puppet/resource/status'

class Puppet::Transaction::ResourceHarness
  NO_ACTION = Object.new

  extend Forwardable
  def_delegators :@transaction, :relationship_graph

  attr_reader :transaction

  def initialize(transaction)
    @transaction = transaction
  end

  def evaluate(resource)
    status = Puppet::Resource::Status.new(resource)

    begin
      context = ResourceApplicationContext.from_resource(resource, status)
      perform_changes(resource, context)

      if status.changed? && ! resource.noop?
        cache(resource, :synced, Time.now)
        resource.flush if resource.respond_to?(:flush)
      end
    rescue => detail
      status.failed_because(detail)
    ensure
      status.evaluation_time = Time.now - status.time
    end

    status
  end

  def scheduled?(resource)
    return true if Puppet[:ignoreschedules]
    return true unless schedule = schedule(resource)

    # We use 'checked' here instead of 'synced' because otherwise we'll
    # end up checking most resources most times, because they will generally
    # have been synced a long time ago (e.g., a file only gets updated
    # once a month on the server and its schedule is daily; the last sync time
    # will have been a month ago, so we'd end up checking every run).
    schedule.match?(cached(resource, :checked).to_i)
  end

  def schedule(resource)
    unless resource.catalog
      resource.warning "Cannot schedule without a schedule-containing catalog"
      return nil
    end

    return nil unless name = resource[:schedule]
    resource.catalog.resource(:schedule, name) || resource.fail("Could not find schedule #{name}")
  end

  # Used mostly for scheduling and auditing at this point.
  def cached(resource, name)
    Puppet::Util::Storage.cache(resource)[name]
  end

  # Used mostly for scheduling and auditing at this point.
  def cache(resource, name, value)
    Puppet::Util::Storage.cache(resource)[name] = value
  end

  private

  def perform_changes(resource, context)
    cache(resource, :checked, Time.now)

    # Record the current state in state.yml.
    context.audited_params.each do |param|
      cache(resource, param, context.current_values[param])
    end

    ensure_param = resource.parameter(:ensure)
    if ensure_param && ensure_param.should
      ensure_event = sync_if_needed(ensure_param, context)
    else
      ensure_event = NO_ACTION
    end

    if ensure_event == NO_ACTION
      if context.resource_present?
        resource.properties.each do |param|
          sync_if_needed(param, context)
        end
      else
        resource.debug("Nothing to manage: no ensure and the resource doesn't exist")
      end
    end

    capture_audit_events(resource, context)
  end

  def sync_if_needed(param, context)
    historical_value = context.historical_values[param.name]
    current_value = context.current_values[param.name]
    do_audit = context.audited_params.include?(param.name)

    begin
      if param.should && !param.safe_insync?(current_value)
        event = create_change_event(param, current_value, historical_value)
        if do_audit
          event = audit_event(event, param, context)
        end

        brief_audit_message = audit_message(param, do_audit, historical_value, current_value)

        if param.noop
          noop(event, param, current_value, brief_audit_message)
        else
          sync(event, param, current_value, brief_audit_message)
        end

        event
      else
        NO_ACTION
      end
    rescue => detail
      # Execution will continue on StandardErrors, just store the event
      Puppet.log_exception(detail)

      event = create_change_event(param, current_value, historical_value)
      event.status = "failure"
      event.message = param.format("change from %s to %s failed: #{detail}",
                                   param.is_to_s(current_value),
                                   param.should_to_s(param.should))
      event
    rescue Exception => detail
      # Execution will halt on Exceptions, they get raised to the application
      event = create_change_event(param, current_value, historical_value)
      event.status = "failure"
      event.message = param.format("change from %s to %s failed: #{detail}",
                                   param.is_to_s(current_value),
                                   param.should_to_s(param.should))
      raise
    ensure
      if event
        context.record(event)
        event.send_log
        context.synced_params << param.name
      end
    end
  end

  def create_change_event(property, current_value, historical_value)
    options = {}
    should = property.should

    if property.sensitive
      options[:previous_value] = current_value.nil? ? nil : '[redacted]'
      options[:desired_value] = should.nil? ? nil : '[redacted]'
      options[:historical_value] = historical_value.nil? ? nil : '[redacted]'
    else
      options[:previous_value] = current_value
      options[:desired_value] = should
      options[:historical_value] = historical_value
    end

    property.event(options)
  end

  # This method is an ugly hack because, given a Time object with nanosecond
  # resolution, roundtripped through YAML serialization, the Time object will
  # be truncated to microseconds.
  # For audit purposes, this code special cases this comparison, and compares
  # the two objects by their second and microsecond components. tv_sec is the
  # number of seconds since the epoch, and tv_usec is only the microsecond
  # portion of time.
  def are_audited_values_equal(a, b)
    a == b || (a.is_a?(Time) && b.is_a?(Time) && a.tv_sec == b.tv_sec && a.tv_usec == b.tv_usec)
  end
  private :are_audited_values_equal

  # Populate an existing event with audit information.
  #
  # @param event [Puppet::Transaction::Event] The event to be populated.
  # @param property [Puppet::Property] The property being audited.
  # @param context [ResourceApplicationContext]
  #
  # @return [Puppet::Transaction::Event] The given event, populated with the audit information.
  def audit_event(event, property, context)
    event.audited = true
    event.status = "audit"

    # The event we've been provided might have been redacted so we need to use the state stored within
    # the resource application context to see if an event was actually generated.
    if !are_audited_values_equal(context.historical_values[property.name], context.current_values[property.name])
      event.message = property.format("audit change: previously recorded value %s has been changed to %s",
                 property.is_to_s(event.historical_value),
                 property.is_to_s(event.previous_value))
    end

    event
  end

  def audit_message(param, do_audit, historical_value, current_value)
    if do_audit && historical_value && !are_audited_values_equal(historical_value, current_value)
      param.format(" (previously recorded value was %s)", param.is_to_s(historical_value))
    else
      ""
    end
  end

  def noop(event, param, current_value, audit_message)
    event.message = param.format("current_value %s, should be %s (noop)#{audit_message}",
                                 param.is_to_s(current_value),
                                 param.should_to_s(param.should))
    event.status = "noop"
  end

  def sync(event, param, current_value, audit_message)
    param.sync
    if param.sensitive
      event.message = param.format("changed %s to %s#{audit_message}", param.is_to_s(current_value), param.should_to_s(param.should))
    else
      event.message = "#{param.change_to_s(current_value, param.should)}#{audit_message}"
    end
    event.status = "success"
  end

  def capture_audit_events(resource, context)
    context.audited_params.each do |param_name|
      if context.historical_values.include?(param_name)
        if !are_audited_values_equal(context.historical_values[param_name], context.current_values[param_name]) && !context.synced_params.include?(param_name)
          parameter = resource.parameter(param_name)
          event = audit_event(create_change_event(parameter,
                                                  context.current_values[param_name],
                                                  context.historical_values[param_name]),
                              parameter, context)
          event.send_log
          context.record(event)
        end
      else
        property = resource.property(param_name)
        property.notice(property.format("audit change: newly-recorded value %s", context.current_values[param_name]))
      end
    end
  end

  # @api private
  ResourceApplicationContext = Struct.new(:resource,
                                          :current_values,
                                          :historical_values,
                                          :audited_params,
                                          :synced_params,
                                          :status) do
    def self.from_resource(resource, status)
      ResourceApplicationContext.new(resource,
                                     resource.retrieve_resource.to_hash,
                                     Puppet::Util::Storage.cache(resource).dup,
                                     (resource[:audit] || []).map { |p| p.to_sym },
                                     [],
                                     status)
    end

    def resource_present?
      resource.present?(current_values)
    end

    def record(event)
      status << event
    end
  end
end
