{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Graphics.Wayland.Test
where

import Graphics.Wayland.TH

$(generateFromXml "/usr/share/wayland/wayland.xml")
