{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

module PaymentServer.Processors.Stripe
  ( StripeAPI
  , stripeServer
  , getVoucher
  , StripeSecretKey
  ) where

import Control.Monad.IO.Class
  ( liftIO
  )
import Control.Monad
  ( mzero
  )
import Control.Exception
  ( try
  , throwIO
  )
import Data.ByteString
  ( ByteString
  )
import Data.Text
  ( Text
  , unpack
  )
import qualified Data.Map as Map
import Text.Read
  ( readMaybe
  )
import Data.Aeson
  ( ToJSON(toJSON)
  , FromJSON(parseJSON)
  , Value(Object)
  , object
  , encode
  , (.:)
  , (.=)
  )
import Servant
  ( Server
  , Handler
  , err400
  , err500
  , ServerError(ServerError, errHTTPCode, errBody, errHeaders, errReasonPhrase)
  , throwError
  )
import Servant.API
  ( ReqBody
  , JSON
  , Post
  , (:>)
  , (:<|>)((:<|>))
  )
import Web.Stripe.Event
  ( Event(Event, eventId, eventType, eventData)
  , EventId(EventId)
  , EventType(ChargeSucceededEvent)
  , EventData(ChargeEvent)
  )
import Web.Stripe.Types
  ( Charge(Charge, chargeMetaData)
  , MetaData(MetaData)
  , Currency
  )
import Web.Stripe.Error
  ( StripeError(StripeError)
  )
import Web.Stripe.Charge
  ( createCharge
  , Amount(Amount)
  , TokenId(TokenId)
  )
import Web.Stripe.Client
  ( StripeConfig(StripeConfig)
  , StripeKey(StripeKey)
  )
import Web.Stripe
  ( stripe
  , (-&-)
  )
import PaymentServer.Persistence
  ( Voucher
  , VoucherDatabase(payForVoucher)
  , PaymentError(AlreadyPaid, PaymentFailed)
  )

type StripeSecretKey = ByteString

data Acknowledgement = Ok

instance ToJSON Acknowledgement where
  toJSON Ok = object
    [ "success" .= True
    ]

type StripeAPI = ChargesAPI

-- | getVoucher finds the metadata item with the key `"Voucher"` and returns
-- the corresponding value, or Nothing.
getVoucher :: MetaData -> Maybe Voucher
getVoucher (MetaData []) = Nothing
getVoucher (MetaData (("Voucher", value):xs)) = Just value
getVoucher (MetaData (x:xs)) = getVoucher (MetaData xs)

stripeServer :: VoucherDatabase d => StripeSecretKey -> d -> Server StripeAPI
stripeServer key d = charge d key

-- | Browser facing API that takes token, voucher and a few other information
-- and calls stripe charges API. If payment succeeds, then the voucher is stored
-- in the voucher database.
type ChargesAPI = "charge" :> ReqBody '[JSON] Charges :> Post '[JSON] Acknowledgement

data Charges = Charges
  { token :: Text          -- ^ The text of a Stripe tokenized payment method.
  , voucher :: Voucher     -- ^ The voucher for which this charge will pay.
  , amount :: Int          -- ^ The amount of the charge in the minimum
                           -- currency unit of the target currency (eg for
                           -- USD, cents).
  , currency :: Text       -- ^ The currency in which the charge will be made.
  } deriving (Show, Eq)

instance FromJSON Charges where
  parseJSON (Object v) = Charges <$>
                         v .: "token" <*>
                         v .: "voucher" <*>
                         (read <$> v .: "amount") <*>
                         v .: "currency"
  parseJSON _ = mzero

-- | call the stripe Charge API (with token, voucher in metadata, amount, currency etc
-- and if the Charge is okay, then set the voucher as "paid" in the database.
charge :: VoucherDatabase d => d -> StripeSecretKey -> Charges -> Handler Acknowledgement
charge d key (Charges token voucher amount currency) = do
  currency' <- getCurrency currency
  result <- liftIO (try (payForVoucher d voucher (completeStripeCharge currency')))
  case result of
    Left AlreadyPaid ->
      throwError voucherAlreadyPaid
    Left PaymentFailed ->
      throwError stripeChargeFailed
    Right Charge { chargeMetaData = metadata } ->
      checkVoucherMetadata metadata
    where
      getCurrency :: Text -> Handler Currency
      getCurrency maybeCurrency =
        case readMaybe (unpack currency) of
          Just currency' -> return currency'
          Nothing -> throwError unsupportedCurrency

      config = StripeConfig (StripeKey key) Nothing
      tokenId = TokenId token
      completeStripeCharge currency' = do
        result <- stripe config $
          createCharge (Amount amount) currency'
          -&- tokenId
          -&- MetaData [("Voucher", voucher)]
        case result of
          Left StripeError {} -> throwIO PaymentFailed
          Right result -> return result

      checkVoucherMetadata :: MetaData -> Handler Acknowledgement
      checkVoucherMetadata metadata =
        -- verify that we are getting the same metadata that we sent.
        case metadata of
          MetaData [("Voucher", v)] ->
            if v == voucher
            then return Ok
            else throwError voucherCodeMismatch
          _ -> throwError voucherCodeNotFound

      voucherCodeMismatch = jsonErr 500 "Voucher code mismatch"
      unsupportedCurrency = jsonErr 400 "Invalid currency specified"
      voucherCodeNotFound = jsonErr 400 "Voucher code not found"
      stripeChargeFailed = jsonErr 400 "Stripe charge didn't succeed"
      voucherAlreadyPaid = jsonErr 400 "Payment for voucher already supplied"

      jsonErr httpCode reason = ServerError
        { errHTTPCode = httpCode
        , errReasonPhrase = ""
        , errBody = encode $ Failure reason
        , errHeaders = [("content-type", "application/json")]
        }


data Failure = Failure Text
  deriving (Show, Eq)


instance ToJSON Failure where
  toJSON (Failure reason) = object
    [ "success" .= False
    , "reason" .= reason
    ]
