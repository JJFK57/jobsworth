# encoding: UTF-8

# A work entry, belonging to a user & task
# Has a duration in seconds for work entries

class WorkLog < ActiveRecord::Base
  has_many(:custom_attribute_values, :as => :attributable, :dependent => :destroy,
           # set validate = false because validate method is over-ridden and does that for us
           :validate => false)
  include CustomAttributeMethods

  belongs_to :_user_, :class_name => "User", :foreign_key => "user_id"
  belongs_to :email_address
  belongs_to :company
  belongs_to :project
  belongs_to :customer
  belongs_to :task, :class_name=>"AbstractTask", :foreign_key=>'task_id'
  belongs_to :access_level

  has_one    :ical_entry, :dependent => :destroy
  has_one    :event_log, :as => :target, :dependent => :destroy
  has_many    :work_log_notifications, :dependent => :destroy
  has_many    :users, :through => :work_log_notifications
  has_many   :email_deliveries

  scope :comments, where("work_logs.comment = ? or work_logs.log_type = ?", true, EventLog::TASK_COMMENT)
  #check all access rights for user
  scope :on_tasks_owned_by, lambda { |user|
    select("work_logs.*").joins("INNER JOIN tasks ON work_logs.task_id = tasks.id INNER JOIN task_users ON work_logs.task_id = task_users.task_id").where("task_users.user_id = ?", user)
  }
  scope :accessed_by, lambda { |user|
    readonly(false).joins(
      "join projects on work_logs.project_id = projects.id join project_permissions on project_permissions.project_id = projects.id join users on project_permissions.user_id= users.id"
    ).includes(:task).where(
      "projects.completed_at is NULL and users.id=? and (project_permissions.can_see_unwatched = 1 or users.id in(select task_users.user_id from task_users where task_users.task_id=tasks.id)) and work_logs.company_id = ? AND work_logs.access_level_id <= ? ", user.id, user.company_id, user.access_level_id
    )
  }

  scope :level_accessed_by, lambda { |user|
    where("work_logs.access_level_id <= ?", user.access_level_id)
  }

  scope :all_accessed_by, lambda { |user|
    readonly(false).includes(:task).joins(
      "join project_permissions on work_logs.project_id = project_permissions.project_id join users on project_permissions.user_id= users.id"
    ).where(
      "users.id = ? and (project_permissions.can_see_unwatched=1 or users.id in (select task_users.user_id from task_users where task_users.task_id=tasks.id)) and work_logs.access_level_id <= ?", user.id, user.access_level_id
    )
  }

  validates_presence_of :started_at
  validate :validate_logs

  after_update { |r|
    r.ical_entry.destroy if r.ical_entry
    l = r.event_log
    l.created_at = r.started_at
    l.save

    if r.task && r.duration.to_i > 0
      r.task.recalculate_worked_minutes
      r.task.save
    end

  }

  after_create { |r|
    l = r.create_event_log
    l.company_id = r.company_id
    l.project_id = r.project_id
    l.user_id = r.user_id
    l.event_type = r.log_type
    l.created_at = r.started_at
    l.save

    if r.task && r.duration.to_i > 0
      r.task.recalculate_worked_minutes
      r.task.save
    end

  }

  after_destroy { |r|
    if r.task
      r.task.recalculate_worked_minutes
      r.task.save
    end

  }

  ###
  # Creates and saves a worklog for the given task.
  # The newly created worklog is returned.
  # If anything goes worng, raise an exception
  ###
  def self.create_task_created!(task, user)
    worklog = WorkLog.new
    worklog.user = user
    worklog.for_task(task)
    worklog.log_type = EventLog::TASK_CREATED
    worklog.body=   task.description

    #worklog.comment = ??????
    worklog.save!

    return worklog
  end

  # Builds a new (unsaved) work log for task using the given params
  # params must look like {:work_log=>{...},:comment=>""}
  # build only if we have :duration or :comment else retur false
  def self.build_work_added_or_comment(task, user, params=nil)
    work_log_params=params[:work_log].nil? ? {} : params[:work_log].clone
    if (work_log_params and !work_log_params[:duration].blank?) or (params and !params[:comment].blank?)
      unless params[:comment].blank?
        work_log_params[:body] = params[:comment]
        work_log_params[:log_type]=EventLog::TASK_COMMENT
        work_log_params[:comment] =true
      end
      unless work_log_params[:duration].blank?
        work_log_params[:duration] = TimeParser.parse_time(user, work_log_params[:duration])
        work_log_params[:started_at] = TimeParser.date_from_params(user, work_log_params, :started_at)
        work_log_params[:log_type] = EventLog::TASK_WORK_ADDED
      else
        work_log_params[:duration]=0
        work_log_params[:started_at]=Time.now.utc
      end
      work_log_params[:user]=user
      work_log_params[:company]= task.company
      work_log_params[:project] = task.project
      work_log_params[:customer] = (task.customers.first || task.project.customer)
      task.work_logs.build( work_log_params)
    else
      return false
    end
  end

  def ended_at
    self.started_at + self.duration + self.paused_duration
  end

  # Sets the associated customer using the given name
  def customer_name=(name)
    self.customer = company.customers.find_by_name(name)
  end
  # Returns the name of the associated customer
  def customer_name
    customer.name if customer
  end

  def validate_logs
    if log_type == EventLog::TASK_WORK_ADDED
      validate_custom_attributes
    end
  end

  def notify(update_type= :comment, files=[])
    mark_as_unread
    emails = task.email_addresses
    users = task.users_to_notify(user).select{ |user| user.access_level_id >= self.access_level_id }
    emails += users.map { |u| u.email_addresses.detect{ |pv| pv.default } }
    emails = emails.uniq.compact
    self.users = users

    emails.each do |email|
      EmailDelivery.new(:status=>"queued", :email_address=>email, :work_log=>self).save!
    end
    if Rails.env == 'production'
      send_later(:send_notifications,update_type, files)
    else
      send_notifications(update_type, files)
    end
  end

  def for_task(task)
    self.task=task
    self.project=task.project
    self.company= task.project.company
    self.customer= task.project.customer
    self.started_at= Time.now.utc
    self.duration = 0
  end

  #create user accessor to rewrite user association
  def user
    if _user_.nil?
      User.new(:name=>"Unknown User (#{email_address.email})", :email=> email_address, :company => company)
    else
      _user_
    end
  end

  def user=(u)
    self._user_ = u
  end

private
  ###
  # This method will set up notifications. A block should be passed that will
  # send the actual emails, but this method will update the owners, worklog, etc
  # as required.
  ###
  def setup_notifications(&block)
    email_deliveries.where("status='queued'").each do |delivery|
      yield(delivery.email_address.email)
      delivery.status= 'sent'
      delivery.save!

      append_delivered_email_address_to_body(delivery)
    end
  end

  ###
  # this function will send notifications
  # only if work log have comment or log type TASK_CREATED
  ###
  def send_notifications(update_type= :comment, files)
    if (self.comment? and self.log_type != EventLog::TASK_CREATED) or self.log_type == EventLog::TASK_COMMENT
        setup_notifications do |recipients|
            email_body= self.user.name + ":\n"
            email_body<< self.body
            Notifications.changed(update_type, self.task, self.user, recipients, email_body, files).deliver
          end
    else
      if self.log_type == EventLog::TASK_CREATED
        setup_notifications do |recipients|
          #note send without comment, user add comment will be sended another mail
          Notifications.created(self.task, self.user, recipients, files).deliver
        end
      else
        #we don't have comment
        #don't bother our users
      end
    end
  end

  def mark_as_unread
    ids = task.users.where(["users.access_level_id <?", access_level_id]).select("users.id").map{ |u| u.id } << user_id
    task.mark_as_unread(["user_id not in (?)", ids])
  end
  
  def append_delivered_email_address_to_body(delivery)
    if self.body.blank? || self.body.index("Notification emails sent to").nil?
      self.body += "\n\n" unless self.body.blank?
      self.body += "Notification emails sent to #{delivery.email_address.username_and_email}"
    else
      self.body += ", #{delivery.email_address.username_and_email}"
    end
    self.save
  end
end


# == Schema Information
#
# Table name: work_logs
#
#  id               :integer(4)      not null, primary key
#  user_id          :integer(4)      default(0), not null
#  task_id          :integer(4)
#  project_id       :integer(4)      default(0), not null
#  company_id       :integer(4)      default(0), not null
#  customer_id      :integer(4)      default(0), not null
#  started_at       :datetime        not null
#  duration         :integer(4)      default(0), not null
#  body             :text
#  log_type         :integer(4)      default(0)
#  paused_duration  :integer(4)      default(0)
#  comment          :boolean(1)      default(FALSE)
#  exported         :datetime
#  approved         :boolean(1)
#
# Indexes
#
#  work_logs_user_id_index      (user_id,task_id)
#  work_logs_task_id_index      (task_id,log_type)
#  work_logs_company_id_index   (company_id)
#  work_logs_project_id_index   (project_id)
#  work_logs_customer_id_index  (customer_id)
#

