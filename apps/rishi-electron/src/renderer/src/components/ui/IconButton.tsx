import React from 'react'

interface IconButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  size?: 'small' | 'medium' | 'large'
  color?: 'primary' | 'secondary' | 'error' | 'inherit'
  children: React.ReactNode
}

export const IconButton: React.FC<IconButtonProps> = ({
  size = 'medium',
  color = 'primary',
  children,
  className = '',
  disabled,
  ...props
}) => {
  const baseClasses =
    'inline-flex items-center justify-center rounded-full transition-all duration-200 focus:outline-none focus:ring-2 focus:ring-offset-2 disabled:opacity-50 disabled:cursor-not-allowed relative overflow-hidden group'

  const sizeClasses = {
    small: 'p-1.5',
    medium: 'p-2.5',
    large: 'p-3.5'
  }

  const colorClasses = {
    primary:
      'text-blue-600 hover:bg-blue-50 focus:ring-blue-500 hover:shadow-md transform hover:-translate-y-0.5 active:translate-y-0',
    secondary:
      'text-gray-600 hover:bg-gray-50 focus:ring-gray-500 hover:shadow-md transform hover:-translate-y-0.5 active:translate-y-0',
    error:
      'text-red-600 hover:bg-red-50 focus:ring-red-500 hover:shadow-md transform hover:-translate-y-0.5 active:translate-y-0',
    inherit:
      'text-current hover:bg-gray-100 focus:ring-gray-500 hover:shadow-md transform hover:-translate-y-0.5 active:translate-y-0'
  }

  const classes = `${baseClasses} ${sizeClasses[size]} ${colorClasses[color]} ${className}`

  return (
    <button className={classes} disabled={disabled} {...props}>
      {/* Ripple effect */}
      <div className="absolute inset-0 rounded-full bg-current opacity-0 group-hover:opacity-10 transition-opacity duration-200" />

      {/* Shine effect */}
      <div className="absolute inset-0 bg-gradient-to-r from-transparent via-white/30 to-transparent -translate-x-full group-hover:translate-x-full transition-transform duration-500 rounded-full" />

      <span className="relative z-10">{children}</span>
    </button>
  )
}
