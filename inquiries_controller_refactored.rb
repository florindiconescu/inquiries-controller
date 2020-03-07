# frozen_string_literal: true

#  **** Florin ****
# I tried to cut out of the CRUD controller methods all the unspecific code.
# All this unspecific to controller code is now moved into private methods.
# The following code can still be improved, but I would prefer to move
# most of those private methods in Service Objects
# For exapmple, instead of the @inquiry = new_inquiry(@gig),
# I would do @inquiry = BuildInquiryService.perform(@gig, current_profile)
# And in the same manner, most of the private methods
# can be removed form the controller
#  **** Florin ****
class Gigs::InquiriesController < Gigs::ApplicationController
  load_and_authorize_resource

  respond_to :html, only: %i[new show]
  respond_to :json, only: :create

  before_filter :load_gig, only: %i[create new]

  def new
    @inquiry = new_inquiry(@gig)
    calc_gig_fixed_fee(@inquiry) if @gig.fixed_fee_negotiable
    @is_matching = GigTest::Matcher.new(@gig, current_profile).matches?
    if current_profile.billing_address.blank? || current_profile.tax_rate.blank?
      @profile = gig_profile
    end
    run_intercom_events(@gig)
  end

  def create
    @inquiry = create_inquiry(@gig)
    #  **** Florin ****
    # I have removed the @inquiry.valid? as it was useless:
    # - if .valid? is true, then .save will be for sure executed!
    # - same goes if .valid is false, that .save won't be performed either
    #  **** Florin ****
    build_riders(@inquiry) if @inquiry.valid?
    if @inquiry.save
      setup_technical_rider(@inquiry, current_profile.technical_rider)
      setup_catering_rider(@inquiry, current_profile.catering_rider)
      after_save_steps
      render json: @inquiry, status: :created
    else
      render json: @inquiry.errors, status: :unprocessable_entity
    end
  end

  # only promoter use this
  def show
    # this redirect is for unfixed legacy links, because artist see inquiries
    # not prefixed with gig in the url
    redirect_to inquiry_path(@inquiry.id) && return if current_profile.artist?
    Event::Read.emit(:inquiry, @inquiry.id)
  end

  private

  def load_gig
    #  **** Florin ****
    # Since we have the params[:gig_id],
    # this is more explicit and more effcient:
    #  **** Florin ****
    @gig = Gig.find(params[:gig_id])
  end

  def new_inquiry(gig)
    {
      gig: gig,
      deal_possible_fee_min: gig.deal_possible_fee_min,
      artist_contact: current_profile.last_inquired(:artist_contact),
      travel_party_count: current_profile.last_inquired(:travel_party_count),
      custom_fields: gig.custom_fields,
      fixed_fee: (0 if gig.fixed_fee_option && gig.fixed_fee_max.zero?),
      # set this rider here for new
      # if user keeps it until create, they will be copied async
      # otherwise he can pseudo delete the riders in the Inquiry#new form and
      # add new ones
      technical_rider: current_profile.technical_rider,
      catering_rider: current_profile.catering_rider
    }
  end

  def gig_profile
    profile = current_profile
    if profile.billing_address.blank?
      profile.build_billing_address
      profile.billing_address.name = "#{profile.main_user.first_name} #{profile.main_user.last_name}"
    end
    profile
  end

  def calc_gig_fixed_fee(inquiry)
    inquiry.gig.fixed_fee_option = true
    inquiry.gig.fixed_fee_max = 0
  end

  def run_intercom_events(gig)
    unless current_profile.has_a_complete_billing_address?
      GigTest::Intercom::Event::ApplicationSawIncompleteBillingDataWarning.emit(gig.id, current_profile.id)
    end
    unless current_profile.epk_complete?
      GigTest::Intercom::Event::ApplicationSawIncompleteEpkWarning.emit(gig.id, current_profile.id)
    end
    if current_profile.complete_for_inquiry?
      GigTest::Intercom::Event::ApplicationVisitedGigApplicationForm.emit(gig.id, current_profile.id)
    end
  end

  def create_inquiry(gig)
    {
      gig: gig,
      artist: current_profile,
      user: current_profile.main_user,
      promoter: gig.promoter,
      existing_gig_invite: current_profile.gig_invites.where(gig_id: params[:gig_id]).first
    }
  end

  def setup_technical_rider(inquiry, rider)
    if rider.present? && rider.item_hash == params[:inquiry][:technical_rider_hash]
      inquiry.build_technical_rider(user_id: current_user.id).save!
      MediaItemWorker.perform_async(rider.id, inquiry.technical_rider.id)
    end
  end

  def setup_catering_rider(inquiry, rider)
    if rider.present? && rider.item_hash == params[:inquiry][:catering_rider_hash]
      inquiry.build_catering_rider(user_id: current_user.id).save!
      MediaItemWorker.perform_async(rider.id, inquiry.catering_rider.id)
    end
  end

  def build_rider(rider, inquiry)
    inquiry.build_technical_rider(user_id: current_user.id).save!
    MediaItemWorker.perform_async(rider.id, inquiry.technical_rider.id)
  end

  def after_save_steps
    Event::WatchlistArtistInquiry.emit(@inquiry.id)
    GigTest::Intercom::Event::Simple.emit('gig-received-application', @gig.promoter_id)
    IntercomCreateOrUpdateUserWorker.perform_async(@gig.promoter_id)
    id = existing_gig_invite.id
    Event::Read.emit(:gig_invite, id) if existing_gig_invite.present?
  end
end
