module OpenGov
  class Bills < Resources
    VOTES_DIR = File.join(FIFTYSTATES_DIR, "api", "votes")

    class << self
      def fetch
        # TODO: This is temporary, as we figure out with Sunlight where these bills
        # will really come from.

        FileUtils.mkdir_p(FIFTYSTATES_DIR)
        Dir.chdir(FIFTYSTATES_DIR)

        fiftystates_fn = 'tx.zip'
        curl_ops = File.exists?(fiftystates_fn) ? "-z #{fiftystates_fn}" : ''

        puts "Downloading the bills for Texas"
        `curl #{curl_ops} -fO http://fiftystates-dev.sunlightlabs.com/data/tx.zip`
        `unzip -u #{fiftystates_fn}`
      end

      # TODO: The :remote => false option only applies to the intial import.
      # after that, we always want to use import_one(state)
      def import!(options = {})
        if options[:remote]
          State.loadable.each do |state|
            import_one(state)
          end
        else
          state_dir = File.join(FIFTYSTATES_DIR, "api", "tx")

          unless File.exists?(state_dir)
            puts "Fifty States data is missing; skipping import."
            return
          end

          # TODO: Lookup currently active session
          [81, 811].each do |session|
            [GovKit::FiftyStates::CHAMBER_LOWER, GovKit::FiftyStates::CHAMBER_UPPER].each do |house|
              bills_dir = File.join(state_dir, session.to_s, house, "bills")
              all_bills = File.join(bills_dir, "*")
              Dir.glob(all_bills).each do |file|
                bill = GovKit::FiftyStates::Bill.parse(JSON.parse(File.read(file)))
                import_bill(bill, State.find_by_abbrev('TX'), options)
              end
            end
          end
        end
      end

      def import_one(state)
        puts "Importing bills for #{state.name} \n"

        # TODO: This isn't quite right...
        bills = GovKit::FiftyStates::Bill.latest(Bill.maximum(:updated_at).to_date, state.abbrev.downcase)

        if bills.empty?
          puts "No bills found \n"
        else
          bills.each do |bill|
            import_bill(bill, state, {})
          end
        end
      end

      def import_bill(bill, state, options)
        print "Importing #{bill.bill_id}.."

        @bill = Bill.find_or_create_by_bill_number(bill.bill_id)
        @bill.title = bill.title
        @bill.fiftystates_id = bill[:id]
        @bill.state = state
        @bill.chamber = state.legislature.instance_eval("#{bill.chamber}_chamber")
        @bill.session = state.legislature.sessions.find_by_name(bill.session)
        @bill.first_action_at = valid_date!(bill.first_action)
        @bill.last_action_at = valid_date!(bill.last_action)

        # There is no unique data on a bill's actions that we can key off of, so we
        # must delete and recreate them all each time.
        @bill.actions.clear
        bill.actions.each do |action|
          @bill.actions << Action.new(
            :actor => action.actor,
            :action => action.action,
            :date => valid_date!(action.date))
        end

        bill.versions.each do |version|
          v = Version.find_or_initialize_by_bill_id_and_name(@bill.id, version.name)
          v.url = version.url
          v.save!
        end

        # Same deal as with actions, above
        Sponsorship.delete_all(:bill_id => @bill.id)
        bill.sponsors.each do |sponsor|
          Sponsorship.create(
            :bill => @bill,
            :sponsor => Person.find_by_fiftystates_id(sponsor.leg_id.to_s),
            :kind => sponsor[:type]
          )
        end

        bill.votes.each do |vote|
          v = @bill.votes.find_or_initialize_by_fiftystates_id(vote.vote_id.to_s)
          v.update_attributes!(
            :yes_count => vote.yes_count,
            :no_count => vote.no_count,
            :other_count => vote.other_count,
            :passed => vote.passed,
            :date => valid_date!(vote.date),
            :motion => vote.motion,
            :chamber => state.legislature.instance_eval("#{vote.chamber}_chamber")
          )

          vote_file = File.join(VOTES_DIR, vote.vote_id.to_s)
          if File.exists?(vote_file) && !options[:remote]
            roll_call = GovKit::FiftyStates::Vote.parse(JSON.parse(File.read(vote_file)))
          else
            roll_call = GovKit::FiftyStates::Vote.find(vote.vote_id)
          end

          if roll_call[:roll]
            RollCall.delete_all(:vote_id => vote.vote_id)
            roll_call.roll.each do |roll|
              v.roll_calls << RollCall.new(
                :person => Person.find_by_fiftystates_id(roll.leg_id.to_s),
                :vote_type => roll['type']
              )
            end
          end
        end

        @bill.save!
        puts "done\n"
      end
    end
  end
end
