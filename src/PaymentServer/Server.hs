{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE OverloadedStrings #-}

-- | This module exposes a Servant-based Network.Wai server for payment
-- interactions.
module PaymentServer.Server
  ( paymentServerApp
  ) where

import Network.Wai.Middleware.Cors
  ( Origin
  , CorsResourcePolicy(corsOrigins, corsMethods, corsRequestHeaders)
  , simpleCorsResourcePolicy
  , cors
  )
import Servant
  ( Proxy(Proxy)
  , Server
  , Application
  , serve
  , (:>)
  , (:<|>)((:<|>))
  )
import PaymentServer.Processors.Stripe
  ( StripeAPI
  , StripeSecretKey
  , stripeServer
  )
import PaymentServer.Redemption
  ( RedemptionAPI
  , redemptionServer
  )
import PaymentServer.Issuer
  ( Issuer
  )
import PaymentServer.Persistence
  ( VoucherDatabase
  )

-- | This is the complete type of the server API.
type PaymentServerAPI
  =    "v1" :> "stripe" :> StripeAPI
  :<|> "v1" :> "redeem" :> RedemptionAPI

-- | Create a server which uses the given database.
paymentServer :: VoucherDatabase d => StripeSecretKey -> Issuer -> d -> Server PaymentServerAPI
paymentServer key issuer database =
  stripeServer key database
  :<|> redemptionServer issuer database

paymentServerAPI :: Proxy PaymentServerAPI
paymentServerAPI = Proxy

-- | Create a Servant Application which serves the payment server API using
-- the given database.
paymentServerApp
  :: VoucherDatabase d
  => [Origin]              -- ^ A list of CORS Origins to accept.
  -> StripeSecretKey
  -> Issuer
  -> d
  -> Application
paymentServerApp corsOrigins key issuer =
  let
    app = serve paymentServerAPI . paymentServer key issuer
    withCredentials = False
    corsResourcePolicy = simpleCorsResourcePolicy
                         { corsOrigins = Just (corsOrigins, withCredentials)
                         , corsMethods = [ "POST" ]
                         , corsRequestHeaders = [ "Content-Type" ]
                         }
    cors' = cors (const $ Just corsResourcePolicy)
  in
    cors' . app
