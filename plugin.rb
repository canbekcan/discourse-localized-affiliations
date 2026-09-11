# frozen_string_literal: true

# name: discourse-localized-affiliations
# about: Automatically resolves and applies a user's institutional affiliation based on their email domain, with multi-language support
# version: 1.0.1
# authors: Can Bekcan
# url: https://github.com/canbekcan/discourse-localized-affiliations

enabled_site_setting :localized_affiliations_enabled

after_initialize do
  module ::DiscourseLocalizedAffiliations
    AFFILIATION_FIELD_NAMES = ["affiliation", "kurum / üniversite"].freeze

    def self.find_affiliation_field
      UserField.find_by("LOWER(name) IN (?)", AFFILIATION_FIELD_NAMES)
    end

    def self.ensure_affiliation_field!
      field = find_affiliation_field

      if field
        field.update!(
          editable: false,
          show_on_profile: true,
          show_on_user_card: true
        )
      else
        field = UserField.create!(
          name: "Affiliation",
          description: "Institution assigned automatically based on your email domain.",
          field_type: "text",
          editable: false,
          required: false,
          show_on_profile: true,
          show_on_user_card: true
        )
      end

      field
    rescue => e
      Rails.logger.error("DiscourseLocalizedAffiliations setup error: #{e.message}")
      find_affiliation_field
    end

    def self.resolve_institution(email)
      return nil if email.blank?

      domain = email.to_s.split("@").last.to_s.downcase
      institutions = I18n.t("localized.institutions", default: {})
      return nil unless institutions.is_a?(Hash)

      (institutions[domain.to_sym] || institutions[domain]).presence
    end

    def self.update_user_affiliation(user, field = nil)
      return if user.blank?

      field ||= find_affiliation_field
      return if field.blank?

      primary_email = user.primary_email&.email || user.email
      target_value = resolve_institution(primary_email)
      field_key = "user_field_#{field.id}"

      if user.custom_fields[field_key] != target_value
        user.custom_fields[field_key] = target_value
        user.save_custom_fields
      end
    end

    def self.sync_all_existing_users!(field = nil)
      field ||= find_affiliation_field
      return if field.blank?

      User.human_users.includes(:primary_email, :user_emails).find_each do |user|
        update_user_affiliation(user, field)
      end
    rescue => e
      Rails.logger.warn("DiscourseLocalizedAffiliations sync error: #{e.message}")
    end
  end

  # --- Initial setup: runs conditionally on every boot / rebuild / restart ---
  if SiteSetting.localized_affiliations_enabled
    affiliation_field = ::DiscourseLocalizedAffiliations.ensure_affiliation_field!
    ::DiscourseLocalizedAffiliations.sync_all_existing_users!(affiliation_field)
  end

  # --- Trigger: new user registered ---
  on(:user_created) do |user|
    next unless SiteSetting.localized_affiliations_enabled
    ::DiscourseLocalizedAffiliations.update_user_affiliation(user)
  end

  # --- Trigger: PRIMARY email changed specifically ---
  reloadable_patch do |plugin|
    UserEmail.class_eval do
      after_save :localized_affiliations_sync_on_primary_change

      def localized_affiliations_sync_on_primary_change
        return unless SiteSetting.localized_affiliations_enabled
        return unless saved_change_to_primary? && primary?

        ::DiscourseLocalizedAffiliations.update_user_affiliation(user)
      end
    end
  end

  # --- Trigger: plugin reactivated (site setting toggled back on) ---
  on(:site_setting_changed) do |name, old_value, new_value|
    next unless name.to_s == "localized_affiliations_enabled"
    next unless new_value == true && old_value != true

    field = ::DiscourseLocalizedAffiliations.ensure_affiliation_field!
    ::DiscourseLocalizedAffiliations.sync_all_existing_users!(field)
  end
end