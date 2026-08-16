# frozen_string_literal: true

module XrplReserveStudy
  class OwnerObjectRecipeRegistryError < StudyError; end

  class OwnerObjectRecipeRegistry
    Recipe = Struct.new(:kind, :required_amendments, :creation_steps, :cleanup_steps, :finality_query, :owner_delta, :derived, keyword_init: true)

    def initialize(active_amendments: nil)
      @active_amendments = active_amendments.nil? ? nil : active_amendments.map(&:to_s).freeze
      @recipes = self.class.recipes
    end

    def fetch(kind)
      recipe = @recipes[kind.to_s]
      raise OwnerObjectRecipeRegistryError, "unknown owner object recipe" unless recipe

      return :unsupported_candidate_feature if @active_amendments && !(recipe.required_amendments - @active_amendments).empty?

      recipe
    end

    def all
      @recipes.values.freeze
    end

    class << self
      def recipes
        @recipes ||= begin
          declared = definitions
          validate_definitions!(declared)
          declared.map { |definition| build_recipe(**definition) }.to_h { |recipe| [recipe.kind, recipe] }.freeze
        end
      end

      private

      def build_recipe(kind:, amendments: [], create:, cleanup:, finality:, owner_delta: 1, derived: false)
        Recipe.new(
          kind: kind.freeze,
          required_amendments: amendments.map(&:freeze).freeze,
          creation_steps: build_steps(create),
          cleanup_steps: build_steps(cleanup),
          finality_query: finality.freeze,
          owner_delta: owner_delta,
          derived: derived
        ).freeze
      end

      def definitions
        [
          { kind: "check", create: ["CheckCreate"], cleanup: ["CheckCash"], finality: account_objects("Check") },
          { kind: "deposit_preauthorization", create: ["DepositPreauth"], cleanup: ["DepositPreauth"], finality: account_objects("DepositPreauth") },
          { kind: "escrow", create: ["EscrowCreate"], cleanup: ["EscrowCancel"], finality: account_objects("Escrow") },
          { kind: "nftoken_offer", amendments: ["NonFungibleTokensV1_1"], create: ["NFTokenCreateOffer"], cleanup: ["NFTokenCancelOffer"], finality: account_objects("NFTokenOffer") },
          { kind: "nftoken_page", amendments: ["NonFungibleTokensV1_1"], create: [{ "transaction_type" => "NFTokenMint", "direct_injection" => false, "validated_observation" => true }], cleanup: ["NFTokenBurn"], finality: account_objects("NFTokenPage"), derived: true },
          { kind: "offer", create: ["OfferCreate"], cleanup: ["OfferCancel"], finality: account_objects("Offer") },
          { kind: "oracle", amendments: ["PriceOracle"], create: ["OracleSet"], cleanup: ["OracleDelete"], finality: account_objects("Oracle") },
          { kind: "payment_channel", create: ["PaymentChannelCreate"], cleanup: ["PaymentChannelClaim"], finality: account_objects("PayChannel") },
          { kind: "signer_list", create: ["SignerListSet"], cleanup: ["SignerListSet"], finality: account_objects("SignerList") },
          { kind: "ticket", create: ["TicketCreate"], cleanup: ["TicketCancel"], finality: account_objects("Ticket") },
          { kind: "trust_line", create: ["TrustSet"], cleanup: ["TrustSet"], finality: account_objects("RippleState") },
          { kind: "amm", amendments: ["AMM"], create: ["AMMCreate"], cleanup: ["AMMWithdraw"], finality: account_objects("AMM") },
          { kind: "credential", amendments: ["Credentials"], create: ["CredentialCreate"], cleanup: ["CredentialDelete"], finality: account_objects("Credential") },
          { kind: "did", amendments: ["DID"], create: ["DIDSet"], cleanup: ["DIDDelete"], finality: account_objects("DID") },
          { kind: "mptoken", amendments: ["MPTokensV1"], create: ["MPTokenAuthorize"], cleanup: ["MPTokenAuthorize"], finality: account_objects("MPToken") },
          { kind: "mpt_issuance", amendments: ["MPTokensV1"], create: ["MPTokenIssuanceCreate"], cleanup: ["MPTokenIssuanceDestroy"], finality: account_objects("MPTIssuance") },
          { kind: "permissioned_domain", amendments: ["PermissionedDomains"], create: ["PermissionedDomainSet"], cleanup: ["PermissionedDomainDelete"], finality: account_objects("PermissionedDomain") },
          { kind: "delegate", amendments: ["PermissionDelegation"], create: ["DelegateSet"], cleanup: ["DelegateSet"], finality: account_objects("Delegate") },
          { kind: "xchain_owned_claim_id", amendments: ["XChainBridge"], create: ["XChainCreateClaimID"], cleanup: ["XChainClaim"], finality: account_objects("XChainOwnedClaimID") },
          { kind: "xchain_owned_create_account_claim_id", amendments: ["XChainBridge"], create: ["XChainAccountCreateCommit", { "transaction_type" => "XChainAddAccountCreateAttestation", "attestation" => "first", "effect" => "creates_owned_object" }], cleanup: [{ "transaction_type" => "XChainAddAccountCreateAttestation", "attestation" => "required_completion", "effect" => "destroys_owned_object", "protocol_driven" => true }], finality: account_objects("XChainOwnedCreateAccountClaimID") }
        ].freeze
      end

      def validate_definitions!(declared)
        kinds = declared.map { |definition| definition.fetch(:kind) }
        raise OwnerObjectRecipeRegistryError, "owner object recipe kinds must be unique" unless kinds.uniq.length == kinds.length
        unless kinds.sort == OwnerObjectDistribution::CLASSIFIERS.values.sort
          raise OwnerObjectRecipeRegistryError, "owner object recipes must match classifiers"
        end
      end

      def build_steps(steps)
        steps.map do |step|
          value = step.is_a?(Hash) ? step : { "transaction_type" => step }
          value.transform_keys(&:to_s).freeze
        end.freeze
      end

      def account_objects(entry_type)
        { "method" => "account_objects", "ledger_entry_type" => entry_type }.freeze
      end
    end
  end

  RecipeRegistry = OwnerObjectRecipeRegistry
end
